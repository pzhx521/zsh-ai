#!/usr/bin/env zsh

# Utility functions for zsh-ai

# Function to get the standardized system prompt for all providers
_zsh_ai_get_system_prompt() {
    local context="$1"
    # The digest (zsh-ai-digest) reuses the provider request path but needs a
    # completely different system prompt. When ZSH_AI_SYSTEM_PROMPT is set it
    # fully replaces the command-generation prompt below.
    if [[ -n "$ZSH_AI_SYSTEM_PROMPT" ]]; then
        echo "$ZSH_AI_SYSTEM_PROMPT"
        return
    fi
    local base_prompt="You are a zsh command generator. Given the user's natural language request, return a single JSON object describing one runnable zsh command.\n\nIMPORTANT RULES:\n1. Return ONLY a raw JSON object - no markdown, no code fences, no text outside the JSON\n2. The JSON must contain exactly these keys: \"command\", \"explanation\", \"parameters\"\n3. \"command\": the raw, runnable zsh command on a single line - no backticks, no leading \$ prompt, no trailing newline\n4. The command MUST be directly executable as-is. Do NOT use placeholders such as <file>, your-branch, or path/to/dir. If a value is unknown, use a sensible default or let the shell discover it (e.g. \$(git branch --show-current)). Only if a value is truly unavoidable, leave it and call it out in \"explanation\"\n5. Choose platform-correct commands and flags based on the OS in Context: \"Darwin\" means macOS / BSD coreutils, \"Linux\" means GNU coreutils. They differ (e.g. sed -i '' vs sed -i; date -v-7d vs date -d '7 days ago'; stat -f vs stat -c)\n6. For multi-step tasks, chain commands on ONE line with && or | . Never emit a newline inside \"command\"\n7. Prefer non-destructive forms. Do NOT add destructive flags like --force / -f unless the user explicitly asks; when ambiguous, choose the safer variant\n8. If the request cannot be turned into a reliable command, return the closest best-effort command and state the assumption in \"explanation\". Never invent non-existent subcommands or flags\n9. \"explanation\": at most 1-2 short lines describing what the command does\n10. \"parameters\": at most 1-2 short lines explaining the key flags/arguments (use an empty string if there are none)\n11. Reply in the same language as the request (e.g. a Chinese request gets a Chinese explanation and parameters)\n12. In \"command\", quote arguments containing spaces or special characters with single quotes; use double quotes only when variable expansion is needed; escape special characters properly\n13. If the command installs software, an SDK or packages (apt, apt-get, yum, dnf, pacman, brew, npm, pip, pip3, gem, cargo, go, ...), additionally state in \"explanation\" what the installed software/SDK is for (its purpose), not just that it installs it\n\nExamples:\nRequest: delete log files older than 7 days\n{\"command\":\"find . -name '*.log' -mtime +7 -delete\",\"explanation\":\"Find and delete .log files not modified in the last 7 days.\",\"parameters\":\"-mtime +7 = older than 7 days; -delete removes each match.\"}\n\nRequest: show the current user\n{\"command\":\"echo \\\"Current user: \$USER\\\"\",\"explanation\":\"Print the current username.\",\"parameters\":\"\$USER expands to the logged-in user.\"}\n\nRequest: install jq\n{\"command\":\"sudo apt-get install -y jq\",\"explanation\":\"Install jq, a command-line JSON processor used to slice, filter and format JSON data.\",\"parameters\":\"-y auto-confirms the install; jq is the package name.\"}\n\nRequest: 找出占用 8080 端口的进程并杀掉\n{\"command\":\"lsof -ti:8080 | xargs kill -9\",\"explanation\":\"查出监听 8080 端口的进程并强制结束。\",\"parameters\":\"-ti:8080 只输出 PID;xargs 把 PID 传给 kill -9 强制终止。\"}"
    
    # Add custom prompt extension if provided
    if [[ -n "$ZSH_AI_PROMPT_EXTEND" ]]; then
        echo "${base_prompt}\n\n${ZSH_AI_PROMPT_EXTEND}\n\nContext:\n$context"
    else
        echo "${base_prompt}\n\nContext:\n$context"
    fi
}

# Function to properly escape strings for JSON
_zsh_ai_escape_json() {
    # Use printf and perl for reliable JSON escaping
    printf '%s' "$1" | perl -0777 -pe 's/\\/\\\\/g; s/"/\\"/g; s/\t/\\t/g; s/\r/\\r/g; s/\n/\\n/g; s/\f/\\f/g; s/\x08/\\b/g; s/[\x00-\x07\x0B\x0E-\x1F]//g'
}

# Finalize model content for output. Commands must be single-line, so newlines
# are stripped by default; when ZSH_AI_RAW_CONTENT is set (used by the digest,
# which needs multi-line markdown) internal newlines are preserved. Trailing
# whitespace is always trimmed.
_zsh_ai_finalize_content() {
    emulate -L zsh
    if [[ -n "$ZSH_AI_RAW_CONTENT" ]]; then
        printf "%s" "$1" | sed 's/[[:space:]]*$//'
    else
        printf "%s" "$1" | tr -d '\n' | sed 's/[[:space:]]*$//'
    fi
}

# Echo the model name for the currently selected provider.
_zsh_ai_current_model() {
    case "$ZSH_AI_PROVIDER" in
        ollama)  echo "$ZSH_AI_OLLAMA_MODEL" ;;
        gemini)  echo "$ZSH_AI_GEMINI_MODEL" ;;
        openai)  echo "$ZSH_AI_OPENAI_MODEL" ;;
        qwen)    echo "$ZSH_AI_QWEN_MODEL" ;;
        grok)    echo "$ZSH_AI_GROK_MODEL" ;;
        mistral) echo "$ZSH_AI_MISTRAL_MODEL" ;;
        *)       echo "$ZSH_AI_ANTHROPIC_MODEL" ;;
    esac
}

# Strip terminal control characters (including ESC) from model-provided text.
# Model output is printed to the terminal and pushed into the line buffer, so a
# compromised endpoint or prompt-injected reply could otherwise smuggle ANSI
# escape sequences (cursor moves, screen rewrites, etc.) into the display.
_zsh_ai_sanitize() {
    emulate -L zsh
    printf '%s' "${1//[[:cntrl:]]/}"
}

# Like _zsh_ai_sanitize but for multi-line documents: keep newline (\n) and tab
# (\t), strip every other control character (including ESC). Used by the digest
# before writing markdown to disk, so a compromised/prompt-injected reply can't
# smuggle ANSI escape sequences that fire when the .md file is later viewed.
_zsh_ai_sanitize_doc() {
    emulate -L zsh
    printf '%s' "$1" | perl -pe 's/[\x00-\x08\x0B-\x1F\x7F]//g'
}

# Extract a top-level string field from the model's JSON response.
# Prefers jq when available, falls back to perl (a required dependency).
# The result is sanitized of control characters. Returns an empty string when
# the field is missing or the input is not JSON.
_zsh_ai_json_field() {
    emulate -L zsh
    local json="$1" field="$2" result

    # Strip code fences and stray carriage returns the model may add
    json="${json//$'\r'/}"
    json="${json#\`\`\`json}"
    json="${json#\`\`\`}"
    json="${json%\`\`\`}"

    if command -v jq >/dev/null 2>&1; then
        result="$(printf '%s' "$json" | jq -er --arg f "$field" '.[$f] // empty' 2>/dev/null)"
        if [[ $? -eq 0 ]]; then
            _zsh_ai_sanitize "$result"
            return 0
        fi
    fi

    # perl fallback: extract "field":"..." handling escaped characters
    result="$(FIELD="$field" perl -0777 -ne '
        my $f = quotemeta($ENV{FIELD});
        if (/"$f"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
            my $v = $1;
            $v =~ s/\\n/\n/g; $v =~ s/\\t/\t/g; $v =~ s/\\r//g;
            $v =~ s/\\"/"/g; $v =~ s/\\\\/\\/g;
            print $v;
        }
    ' <<< "$json")"
    _zsh_ai_sanitize "$result"
}

# Parse a model response into command/explanation/parameters and print the
# explanation + parameters to stderr (so callers can show them to the user).
# Echoes the bare command on stdout. Falls back to the raw text when the
# response is not JSON, keeping backward compatibility.
_zsh_ai_render_response() {
    local raw="$1"
    local command_str explanation params

    command_str="$(_zsh_ai_json_field "$raw" command)"
    if [[ -z "$command_str" ]]; then
        # Not JSON - treat the whole response as the command
        _zsh_ai_sanitize "$raw"
        return 0
    fi

    explanation="$(_zsh_ai_json_field "$raw" explanation)"
    params="$(_zsh_ai_json_field "$raw" parameters)"

    [[ -n "$explanation" ]] && print -P "%F{cyan}ℹ ${explanation}%f" >&2
    [[ -n "$params" ]] && print -P "%F{8}↳ ${params}%f" >&2

    printf '%s' "$command_str"
}

# Display width of a string in terminal columns (CJK / fullwidth count as 2).
# Matches the standard Unicode East Asian Wide/Fullwidth table.
_zsh_ai_display_width() {
    emulate -L zsh
    setopt local_options multibyte
    local s="$1"
    integer w=0 i
    local c
    for (( i=1; i<=${#s}; i++ )); do
        c="$s[i]"
        if [[ "$c" == [$'ᄀ'-$'ᅟ'$'⺀'-$'〾'$'ぁ'-$'㏿'$'㐀'-$'䶿'$'一'-$'鿿'$'ꀀ'-$'꓏'$'가'-$'힣'$'豈'-$'﫿'$'︰'-$'﹏'$'＀'-$'｠'$'￠'-$'￦'] ]]; then
            (( w += 2 ))
        else
            (( w += 1 ))
        fi
    done
    echo $w
}

# Render the result inside a framed box: the command, its explanation and key
# parameters, and a prominent "confirm before running" warning. Nothing is
# placed in the editable prompt, so the command cannot be run by accident.
# Output goes to stdout using raw ANSI codes (never `print -P`, so a command
# containing `%` is safe).
_zsh_ai_render_box() {
    emulate -L zsh
    setopt local_options multibyte
    local command_str="$1" explanation="$2" params="$3" risk="$4"
    local red=$'\e[31m' cyan=$'\e[36m' gray=$'\e[90m' yellow=$'\e[33m' green=$'\e[32m' bold=$'\e[1m' reset=$'\e[0m'

    local cmd_color warn
    case "$risk" in
        blocked) cmd_color="$red";    warn="XX 命中黑名单,已拒绝,请勿手动执行" ;;
        high)    cmd_color="$red";    warn="!! 高危命令 - 请人工确认无误后再执行" ;;
        medium)  cmd_color="$yellow"; warn="!! 请人工确认无误后再执行" ;;
        *)       cmd_color="$green";  warn="!! 请人工确认无误后再执行" ;;
    esac

    local -a texts colors
    texts=("$command_str"); colors=("$cmd_color$bold")
    [[ -n "$explanation" ]] && { texts+=("说明  $explanation"); colors+=("$cyan"); }
    [[ -n "$params" ]] && { texts+=("参数  $params"); colors+=("$gray"); }
    texts+=("$warn"); colors+=("$yellow$bold")

    integer inner=0 w i n
    local t
    for t in "${texts[@]}"; do
        w=$(_zsh_ai_display_width "$t"); (( w > inner )) && inner=$w
    done
    integer maxw=$(( ${COLUMNS:-80} - 4 )); (( maxw < 20 )) && maxw=20
    (( inner > maxw )) && inner=$maxw

    local hbar=""
    for (( i=0; i<inner+2; i++ )); do hbar+="─"; done

    _zsh_ai_box_line() {
        local txt="$1" col="$2"
        integer ww=$(_zsh_ai_display_width "$txt") pp j
        pp=$(( inner - ww )); (( pp < 0 )) && pp=0
        local sp=""; for (( j=0; j<pp; j++ )); do sp+=" "; done
        print -r -- "${gray}│${reset} ${col}${txt}${reset}${sp} ${gray}│${reset}"
    }

    print -r -- "${gray}╭${hbar}╮${reset}"
    _zsh_ai_box_line "${texts[1]}" "${colors[1]}"
    print -r -- "${gray}├${hbar}┤${reset}"
    n=${#texts[@]}
    if (( n > 2 )); then
        for (( i=2; i<n; i++ )); do _zsh_ai_box_line "${texts[i]}" "${colors[i]}"; done
        print -r -- "${gray}├${hbar}┤${reset}"
    fi
    _zsh_ai_box_line "${texts[n]}" "${colors[n]}"
    print -r -- "${gray}╰${hbar}╯${reset}"
    unfunction _zsh_ai_box_line
}

# Diagnostics for the most recent HTTP request (used by _zsh_ai_error_report)
typeset -g ZSH_AI_LAST_STATUS="" ZSH_AI_LAST_URL="" ZSH_AI_LAST_REQUEST="" ZSH_AI_LAST_RESPONSE=""

# Redact secrets (API keys in URL query params, bearer/x-api-key tokens) for display.
_zsh_ai_redact() {
    printf '%s' "$1" | perl -pe 's/([?&](?:key|api_key|access_token|token)=)[^&\s]+/${1}***REDACTED***/gi; s/(Bearer\s+)\S+/${1}***REDACTED***/gi; s/(x-api-key:\s*)\S+/${1}***REDACTED***/gi'
}

# POST JSON to an endpoint, capturing the body and HTTP status code.
# Usage: _zsh_ai_curl URL PAYLOAD [extra curl header args...]
# Sets ZSH_AI_LAST_{URL,REQUEST,STATUS,RESPONSE} and returns curl's exit code.
# The response body is exposed via $ZSH_AI_LAST_RESPONSE (NOT stdout) so that
# the diagnostics globals survive — capturing via $(...) would run this in a
# subshell and the globals would be lost to the caller's error reporter.
# A sentinel carries the status code so body parsing is unaffected when curl is
# mocked in tests (no sentinel -> status stays empty, body untouched).
_zsh_ai_curl() {
    local url="$1" payload="$2"; shift 2
    ZSH_AI_LAST_URL="$url"
    ZSH_AI_LAST_REQUEST="$payload"
    ZSH_AI_LAST_STATUS=""
    ZSH_AI_LAST_RESPONSE=""

    local raw rc
    raw=$(curl -s -w $'\nZSHAI_HTTP_STATUS:%{http_code}' "$url" "$@" \
        --header "content-type: application/json" \
        --data "$payload" 2>&1)
    rc=$?

    if [[ "$raw" == *$'\n'"ZSHAI_HTTP_STATUS:"* ]]; then
        ZSH_AI_LAST_STATUS="${raw##*ZSHAI_HTTP_STATUS:}"
        ZSH_AI_LAST_RESPONSE="${raw%$'\n'ZSHAI_HTTP_STATUS:*}"
    else
        ZSH_AI_LAST_RESPONSE="$raw"
    fi

    # Optional: append full request/response to the debug log
    if _zsh_ai_debug_enabled 2>/dev/null; then
        {
            print -r -- "[zsh-ai] status=${ZSH_AI_LAST_STATUS:-?} url=$(_zsh_ai_redact "$url")"
            print -r -- "  request : $payload"
            print -r -- "  response: ${ZSH_AI_LAST_RESPONSE}"
        } >> "${ZSH_AI_DEBUG_LOG:-/dev/null}" 2>/dev/null
    fi

    return $rc
}

# Print an error message followed by request diagnostics (status, endpoint,
# request body, raw response) so a failed request can be investigated.
# The caller passes the full message including its prefix (e.g. "API Error: ..").
# Headers are never printed and the URL is redacted, so no API key is leaked.
_zsh_ai_error_report() {
    local msg="$1"
    print -r -- "$msg"
    print -r -- "──────── zsh-ai 诊断信息(排查用)────────"
    print -r -- "HTTP 状态码 : ${ZSH_AI_LAST_STATUS:-N/A}"
    print -r -- "请求地址    : $(_zsh_ai_redact "${ZSH_AI_LAST_URL:-N/A}")"
    print -r -- "请求体      : ${ZSH_AI_LAST_REQUEST:-N/A}"
    print -r -- "原始响应    : ${ZSH_AI_LAST_RESPONSE:-N/A}"
    print -r -- "(注:请求头含密钥,未打印)"
}

# Main query function that routes to the appropriate provider
_zsh_ai_query() {
    local query="$1"

    # The token budget is interpolated verbatim into the JSON request body, so
    # it must be a bare non-negative integer; otherwise a value like
    # '9, "temperature":9' would inject into the payload. Reset if malformed.
    [[ "$ZSH_AI_MAX_TOKENS" == <-> ]] || ZSH_AI_MAX_TOKENS=2048

    if [[ "$ZSH_AI_PROVIDER" == "ollama" ]]; then
        # Check if Ollama is running first
        if ! _zsh_ai_check_ollama; then
            echo "Error: Ollama is not running at $ZSH_AI_OLLAMA_URL"
            echo "Start Ollama with: ollama serve"
            return 1
        fi
        _zsh_ai_query_ollama "$query"
    elif [[ "$ZSH_AI_PROVIDER" == "gemini" ]]; then
        _zsh_ai_query_gemini "$query"
    elif [[ "$ZSH_AI_PROVIDER" == "openai" ]]; then
        _zsh_ai_query_openai "$query"
    elif [[ "$ZSH_AI_PROVIDER" == "qwen" ]]; then
        _zsh_ai_query_qwen "$query"
    elif [[ "$ZSH_AI_PROVIDER" == "grok" ]]; then
        _zsh_ai_query_grok "$query"
    elif [[ "$ZSH_AI_PROVIDER" == "mistral" ]]; then
        _zsh_ai_query_mistral "$query"
    else
        _zsh_ai_query_anthropic "$query"
    fi
}

# Shared function to handle AI command execution
_zsh_ai_execute_command() {
    local query="$1"
    # Note: assign then capture $? separately - `local cmd=$(...)` would mask the
    # command substitution's exit code with the (always-0) exit code of `local`.
    local cmd rc ok=0
    cmd=$(_zsh_ai_query "$query")
    rc=$?

    if (( rc == 0 )) && [[ -n "$cmd" ]] && [[ "$cmd" != "Error:"* ]] && [[ "$cmd" != "API Error:"* ]]; then
        ok=1
    fi

    # Log the request/response (best-effort; never affects the main flow).
    # Runs here, in the same (sub)shell as _zsh_ai_query, so the diagnostics
    # globals it sets (ZSH_AI_LAST_STATUS, ...) are still visible.
    if (( ${+functions[_zsh_ai_log_request]} )); then
        _zsh_ai_log_request "$query" "$cmd" "$rc" "$ok" 2>/dev/null
    fi

    echo "$cmd"
    (( ok )) && return 0 || return 1
}

# Optional: Add a helper function for users who prefer explicit commands
zsh-ai() {
    if [[ $# -eq 0 ]]; then
        echo "Usage: zsh-ai \"your natural language command\""
        echo "Example: zsh-ai \"find all python files modified today\""
        echo ""
        echo "Current provider: $ZSH_AI_PROVIDER"
        if [[ "$ZSH_AI_PROVIDER" == "ollama" ]]; then
            echo "Ollama model: $ZSH_AI_OLLAMA_MODEL"
        elif [[ "$ZSH_AI_PROVIDER" == "gemini" ]]; then
            echo "Gemini model: $ZSH_AI_GEMINI_MODEL"
        elif [[ "$ZSH_AI_PROVIDER" == "openai" ]]; then
            echo "OpenAI model: $ZSH_AI_OPENAI_MODEL"
        elif [[ "$ZSH_AI_PROVIDER" == "qwen" ]]; then
            echo "Qwen model: $ZSH_AI_QWEN_MODEL"
        elif [[ "$ZSH_AI_PROVIDER" == "grok" ]]; then
            echo "Grok model: $ZSH_AI_GROK_MODEL"
        elif [[ "$ZSH_AI_PROVIDER" == "mistral" ]]; then
            echo "Mistral model: $ZSH_AI_MISTRAL_MODEL"
        fi
        return 1
    fi
    
    local query="$*"
    
    # Animation frames - rotating dots (same as widget)
    local dots=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
    local frame=0
    
    # Create a temp file for the response
    local tmpfile=$(mktemp)
    
    # Disable job control notifications (same as widget)
    setopt local_options no_monitor no_notify no_bg_nice

    # Start the API query in background
    (_zsh_ai_execute_command "$query" > "$tmpfile" 2>/dev/null) &
    local pid=$!
    
    # Animate while waiting
    while kill -0 $pid 2>/dev/null; do
        echo -ne "\r${dots[$((frame % ${#dots[@]}))]} "
        ((frame++))
        sleep 0.1
    done
    
    # Clear the line
    echo -ne "\r\033[K"
    
    # Get the response and exit code
    wait $pid
    local exit_code=$?
    local cmd=$(cat "$tmpfile")
    rm -f "$tmpfile"
    
    if [[ $exit_code -eq 0 ]] && [[ -n "$cmd" ]] && [[ "$cmd" != "Error:"* ]] && [[ "$cmd" != "API Error:"* ]]; then
        if [[ "${ZSH_AI_OUTPUT_MODE:l}" == "buffer" ]]; then
            # Legacy mode: paste the command into the prompt to confirm/run
            local parsed_cmd
            parsed_cmd="$(_zsh_ai_render_response "$cmd")"

            # Refuse blacklisted commands before pushing them onto the buffer
            if (( ${+functions[_zsh_ai_risk_level]} )) && _zsh_ai_safety_enabled && \
               [[ "$(_zsh_ai_risk_level "$parsed_cmd")" == "blocked" ]] && \
               [[ "${ZSH_AI_BLACKLIST_ACTION:l}" != "warn" ]]; then
                print -P "%F{red}⛔ zsh-ai 拦截了一条黑名单命令,已拒绝填入:%f"
                print -P "%F{red}$parsed_cmd%f"
                return 1
            fi
            print -z "$parsed_cmd"
        else
            # Box mode: show everything framed; never paste into the prompt
            local parsed_cmd explanation params risk="safe"
            parsed_cmd="$(_zsh_ai_json_field "$cmd" command)"
            [[ -z "$parsed_cmd" ]] && parsed_cmd="$(_zsh_ai_sanitize "$cmd")"
            explanation="$(_zsh_ai_json_field "$cmd" explanation)"
            params="$(_zsh_ai_json_field "$cmd" parameters)"
            (( ${+functions[_zsh_ai_risk_level]} )) && _zsh_ai_safety_enabled && \
                risk="$(_zsh_ai_risk_level "$parsed_cmd")"
            _zsh_ai_render_box "$parsed_cmd" "$explanation" "$params" "$risk"
        fi
    else
        # Show error with better visibility
        echo ""  # Blank line for spacing
        print -P "%F{red}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"
        print -P "%F{red}❌ Failed to generate command%f"
        if [[ -n "$cmd" ]]; then
            # Raw print: diagnostics may contain '%' or multiple lines
            print -r -- $'\e[31m'"$cmd"$'\e[0m'
        fi
        print -P "%F{red}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"
        echo ""  # Blank line for spacing
        return 1
    fi
}
