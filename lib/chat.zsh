#!/usr/bin/env zsh

# Multi-turn agent chat for zsh-ai.
#
# `zsh-ai-chat <agent-id> [first message...]` starts (or resumes) a framed chat
# REPL with an agent (see lib/agents.zsh). The agent's prompt is the system
# message and is never compressed. Conversation turns are appended, one JSON
# line per message, to:
#     $ZSH_AI_LOG_DIR/sessions/<agent-id>/<YYYY-MM-DD>/session-<HHMMSSmmm>.jsonl
# Every ZSH_AI_CHAT_MAX_ROUNDS (default 10) rounds the user is asked whether to
# compress the history: a raw snapshot is kept alongside the session as
#     raw-<session-HHMMSSmmm>-<compress-HHMMSSmmm>.jsonl
# and the live turns are replaced by one model-written summary line.
#
# The request is sent statelessly (the whole message array each turn), which is
# the only multi-turn form every provider supports. Providers are NOT modified:
# _zsh_ai_chat_complete builds the per-provider payload and reuses the shared
# _zsh_ai_curl / _zsh_ai_error_report / _zsh_ai_escape_json / sanitize helpers.

# Return 0 if agent chat can run (request logging dir is set: sessions need it).
_zsh_ai_chat_enabled() { [[ -n "$ZSH_AI_LOG_DIR" ]] }

# Session id = HHMMSSmmm (local time), e.g. 142233871.
_zsh_ai_chat_sid() { date +%H%M%S%3N }

# Human-readable byte size: 1536 -> "1.5 KB".
_zsh_ai_human_size() {
    emulate -L zsh
    local -F b="${1:-0}"
    if (( b < 1024 )); then
        printf '%d B' "$1"
    elif (( b < 1048576 )); then
        printf '%.1f KB' "$(( b / 1024.0 ))"
    else
        printf '%.1f MB' "$(( b / 1048576.0 ))"
    fi
}

# --- request payload (per provider) ----------------------------------------
#
# These read the caller's scope (zsh dynamic scoping, as the digest does):
#   effective_system : string, the system prompt (agent prompt [+ summary])
#   turn_roles[]     : parallel array of "user"/"assistant"
#   turn_contents[]  : parallel array of message bodies

# Build an OpenAI-style messages array. $1=1 prepends the system message.
_zsh_ai_chat_msgs_json() {
    emulate -L zsh
    local include_system="$1"
    local out="[" first=1
    integer i
    if [[ "$include_system" == 1 ]]; then
        out+="{\"role\":\"system\",\"content\":\"$(_zsh_ai_escape_json "$effective_system")\"}"
        first=0
    fi
    for (( i=1; i<=${#turn_roles[@]}; i++ )); do
        (( first )) || out+=","
        first=0
        out+="{\"role\":\"${turn_roles[i]}\",\"content\":\"$(_zsh_ai_escape_json "${turn_contents[i]}")\"}"
    done
    out+="]"
    printf '%s' "$out"
}

# Build a Gemini "contents" array (assistant -> model, content -> parts[].text).
_zsh_ai_chat_contents_json() {
    emulate -L zsh
    local out="[" first=1 grole
    integer i
    for (( i=1; i<=${#turn_roles[@]}; i++ )); do
        (( first )) || out+=","
        first=0
        grole="${turn_roles[i]}"; [[ "$grole" == assistant ]] && grole="model"
        out+="{\"role\":\"$grole\",\"parts\":[{\"text\":\"$(_zsh_ai_escape_json "${turn_contents[i]}")\"}]}"
    done
    out+="]"
    printf '%s' "$out"
}

# Extract assistant text from a response (pure: jq with the given filter, perl
# fallback on the given field name). Prints the content on stdout, empty when
# nothing matched. Error surfacing is the caller's job (no subshell side effects).
_zsh_ai_chat_parse() {
    emulate -L zsh
    local resp="$1" jqf="$2" field="$3" result
    if command -v jq >/dev/null 2>&1; then
        result="$(printf '%s' "$resp" | jq -r "$jqf // empty" 2>/dev/null)"
        if [[ -n "$result" ]]; then printf '%s' "$result"; return 0; fi
        return 1
    fi
    result="$(FIELD="$field" perl -0777 -ne '
        my $f = quotemeta($ENV{FIELD});
        if (/"$f"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
            my $v = $1;
            $v =~ s/\\n/\n/g; $v =~ s/\\t/\t/g; $v =~ s/\\r//g;
            $v =~ s/\\"/"/g; $v =~ s/\\\\/\\/g;
            print $v;
        }
    ' <<< "$resp")"
    [[ -n "$result" ]] && { printf '%s' "$result"; return 0; }
    return 1
}

# Send the current conversation. On success sets ZSH_AI_CHAT_REPLY (multi-line,
# control-chars stripped) and returns 0. On failure sets ZSH_AI_CHAT_ERR (and,
# for connection failures, prints full ZSH_AI_LAST_* diagnostics) and returns 1.
# Must be called WITHOUT command substitution so its globals survive. Reads
# caller scope (effective_system / turn_roles / turn_contents).
_zsh_ai_chat_complete() {
    emulate -L zsh
    ZSH_AI_CHAT_REPLY=""; ZSH_AI_CHAT_ERR=""
    local provider="$ZSH_AI_PROVIDER"
    local maxtok="${ZSH_AI_CHAT_MAX_TOKENS}"
    [[ "$maxtok" == <-> ]] || maxtok=2048
    # Chat replies are free-form prose, so keep newlines when finalizing.
    local ZSH_AI_RAW_CONTENT=1
    # Allow a longer timeout than a single command needs.
    local ZSH_AI_TIMEOUT="${ZSH_AI_CHAT_TIMEOUT:-120}"

    local payload url=() jqf field raw
    local -a hdr=()

    case "$provider" in
        anthropic)
            payload=$(cat <<EOF
{
    "model": "$ZSH_AI_ANTHROPIC_MODEL",
    "max_tokens": ${maxtok},
    "system": "$(_zsh_ai_escape_json "$effective_system")",
    "messages": $(_zsh_ai_chat_msgs_json 0)
}
EOF
)
            hdr=(--header "x-api-key: $ANTHROPIC_API_KEY" --header "anthropic-version: 2023-06-01")
            _zsh_ai_curl "${ZSH_AI_ANTHROPIC_URL}" "$payload" "${hdr[@]}" || {
                ZSH_AI_CHAT_ERR="连接失败,详见诊断信息"
                _zsh_ai_error_report "Error: Failed to connect to Anthropic API" >&2; return 1; }
            jqf='.content[0].text'; field=text
            ;;
        gemini)
            payload=$(cat <<EOF
{
    "contents": $(_zsh_ai_chat_contents_json),
    "systemInstruction": { "parts": [ { "text": "$(_zsh_ai_escape_json "$effective_system")" } ] },
    "generationConfig": { "temperature": 0.3, "maxOutputTokens": ${maxtok}, "thinkingConfig": { "thinkingBudget": 0 } }
}
EOF
)
            _zsh_ai_curl "https://generativelanguage.googleapis.com/v1beta/models/${ZSH_AI_GEMINI_MODEL}:generateContent?key=${GEMINI_API_KEY}" "$payload" || {
                ZSH_AI_CHAT_ERR="连接失败,详见诊断信息"
                _zsh_ai_error_report "Error: Failed to connect to Gemini API" >&2; return 1; }
            jqf='.candidates[0].content.parts[0].text'; field=text
            ;;
        ollama)
            if ! _zsh_ai_check_ollama; then
                ZSH_AI_CHAT_ERR="Ollama is not running at $ZSH_AI_OLLAMA_URL"
                return 1
            fi
            payload=$(cat <<EOF
{
    "model": "$ZSH_AI_OLLAMA_MODEL",
    "messages": $(_zsh_ai_chat_msgs_json 1),
    "stream": false,
    "think": false,
    "options": { "temperature": 0.3, "num_predict": ${maxtok} }
}
EOF
)
            _zsh_ai_curl "${ZSH_AI_OLLAMA_URL}/api/chat" "$payload" || {
                ZSH_AI_CHAT_ERR="连接失败,详见诊断信息"
                _zsh_ai_error_report "Error: Failed to connect to Ollama. Is it running?" >&2; return 1; }
            jqf='.message.content'; field=content
            ;;
        openai|qwen|grok|mistral)
            local model key turl token_param="max_tokens" temp=$',\n    "temperature": 0.3'
            case "$provider" in
                openai)
                    model="$ZSH_AI_OPENAI_MODEL"; turl="$ZSH_AI_OPENAI_URL"
                    key="${ZSH_AI_OPENAI_API_KEY:-$OPENAI_API_KEY}"
                    token_param="max_completion_tokens"
                    [[ "$model" == gpt-4* || "$model" == gpt-3.5* ]] && token_param="max_tokens"
                    # Reasoning models reject a non-default temperature; omit it.
                    [[ "$model" == gpt-5* || "$model" == o1* || "$model" == o3* || "$model" == o4* ]] && temp=""
                    ;;
                qwen)    model="$ZSH_AI_QWEN_MODEL";    turl="$ZSH_AI_QWEN_URL";    key="$QWEN_API_KEY" ;;
                grok)    model="$ZSH_AI_GROK_MODEL";    turl="$ZSH_AI_GROK_URL";    key="$XAI_API_KEY" ;;
                mistral) model="$ZSH_AI_MISTRAL_MODEL"; turl="$ZSH_AI_MISTRAL_URL"; key="$MISTRAL_API_KEY" ;;
            esac
            payload=$(cat <<EOF
{
    "model": "${model}",
    "messages": $(_zsh_ai_chat_msgs_json 1),
    "${token_param}": ${maxtok}${temp}
}
EOF
)
            [[ -n "$key" ]] && hdr=(--header "Authorization: Bearer $key")
            _zsh_ai_curl "${turl}" "$payload" "${hdr[@]}" || {
                ZSH_AI_CHAT_ERR="连接失败,详见诊断信息"
                _zsh_ai_error_report "Error: Failed to connect to ${provider} API" >&2; return 1; }
            jqf='.choices[0].message.content'; field=content
            ;;
        *)
            ZSH_AI_CHAT_ERR="Unsupported provider: $provider"; return 1
            ;;
    esac

    raw="$ZSH_AI_LAST_RESPONSE"
    local content
    content="$(_zsh_ai_chat_parse "$raw" "$jqf" "$field")"
    if [[ -z "$content" ]]; then
        # Surface an API error message if the response carried one.
        local err=""
        command -v jq >/dev/null 2>&1 && \
            err="$(printf '%s' "$raw" | jq -r '.error.message // .error // empty' 2>/dev/null)"
        ZSH_AI_CHAT_ERR="${err:-空响应(可调高 ZSH_AI_CHAT_MAX_TOKENS)}"
        return 1
    fi
    # Strip ANSI/control chars (keep \n \t) before it reaches the terminal/disk.
    content="$(_zsh_ai_sanitize_doc "$content")"
    ZSH_AI_CHAT_REPLY="$(_zsh_ai_finalize_content "$content")"
    return 0
}

# One-shot helper: send a single (system,user) exchange. Isolates its own
# message arrays so it can run from inside a live chat without disturbing the
# conversation. Reply lands in ZSH_AI_CHAT_REPLY (return code mirrors _complete).
_zsh_ai_chat_oneshot() {
    emulate -L zsh
    local effective_system="$1"
    local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("$2")
    _zsh_ai_chat_complete
}

# --- session files ----------------------------------------------------------

# Append one JSON message line to a session file (locked, mode 600).
_zsh_ai_chat_append_line() {
    emulate -L zsh
    local file="$1" role="$2" content="$3"
    local ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
    local line="{\"ts\":\"$(_zsh_ai_escape_json "$ts")\",\"role\":\"$(_zsh_ai_escape_json "$role")\",\"content\":\"$(_zsh_ai_escape_json "$content")\"}"
    _zsh_ai_log_append "$file" "$line"
}

# Parse the last user message from a session file (decoded, single line).
_zsh_ai_chat_last_query() {
    emulate -L zsh
    [[ -r "$1" ]] || return 0
    perl -ne '
        if (/"role":"user"/ && /"content":"((?:[^"\\]|\\.)*)"/) { $last = $1; }
        END {
            if (defined $last) {
                $last =~ s/\\n/ /g; $last =~ s/\\t/ /g; $last =~ s/\\r//g;
                $last =~ s/\\"/"/g; $last =~ s/\\\\/\\/g;
                print $last;
            }
        }
    ' "$1" 2>/dev/null
}

# Truncate a string to N display columns, adding an ellipsis when cut.
_zsh_ai_chat_truncate() {
    emulate -L zsh
    setopt local_options multibyte
    local s="$1"; integer max="${2:-50}" w=0 i
    local c out=""
    for (( i=1; i<=${#s}; i++ )); do
        c="$s[i]"
        if [[ "$c" == [$'ᄀ'-$'ᅟ'$'⺀'-$'〾'$'ぁ'-$'㏿'$'㐀'-$'䶿'$'一'-$'鿿'$'가'-$'힣'$'＀'-$'｠'] ]]; then
            (( w += 2 ))
        else
            (( w += 1 ))
        fi
        (( w > max )) && { out+="…"; break; }
        out+="$c"
    done
    printf '%s' "$out"
}

# List date dirs (YYYY-MM-DD, desc) that contain at least one session, for an agent.
_zsh_ai_chat_agent_dates() {
    emulate -L zsh
    setopt local_options null_glob
    local agent_id="$1"
    local base="$ZSH_AI_LOG_DIR/sessions/$agent_id"
    [[ -d "$base" ]] || return 0
    local d dd
    local -a sf
    for d in "$base"/*(/N); do
        dd="${d:t}"
        [[ "$dd" =~ '^[0-9]{4}-[0-9]{2}-[0-9]{2}$' ]] || continue
        sf=( "$d"/session-*.jsonl(N) )
        (( ${#sf} )) && echo "$dd"
    done | sort -r
}

# List session files (desc) for an agent on a given date.
_zsh_ai_chat_session_files() {
    emulate -L zsh
    setopt local_options null_glob
    local agent_id="$1" date_str="$2"
    local dir="$ZSH_AI_LOG_DIR/sessions/$agent_id/$date_str"
    [[ -d "$dir" ]] || return 0
    local -a sf
    sf=( "$dir"/session-*.jsonl(N) )
    (( ${#sf} )) || return 0
    print -l -- "${(On)sf}"
}

# Format "session-142233871.jsonl" -> "14:22:33".
_zsh_ai_chat_session_time() {
    local sid="${1:t}"; sid="${sid#session-}"; sid="${sid%.jsonl}"
    [[ "$sid" == <-> && ${#sid} -ge 6 ]] && printf '%s:%s:%s' "${sid[1,2]}" "${sid[3,4]}" "${sid[5,6]}" || printf '%s' "$sid"
}

# Interactive session picker. Sets _zsh_ai_chat_chosen_file to the selected
# session path, or "" to start a new session. Reads from the terminal.
_zsh_ai_chat_select_session() {
    emulate -L zsh
    local agent_id="$1" agent_name="$2"
    _zsh_ai_chat_chosen_file=""

    local today="$(date +%Y-%m-%d)"
    local -a all_dates older
    all_dates=( ${(f)"$(_zsh_ai_chat_agent_dates "$agent_id")"} )
    local d
    for d in "${all_dates[@]}"; do [[ "$d" == "$today" ]] || older+=("$d"); done

    local today_has=0
    [[ " ${all_dates[*]} " == *" $today "* ]] && today_has=1

    # No history at all -> just start fresh, no menu.
    if (( ${#all_dates} == 0 )); then
        return 0
    fi

    integer revealed=0 cyan i
    local cy=$'\e[36m' gy=$'\e[90m' bd=$'\e[1m' rs=$'\e[0m' ye=$'\e[33m'
    while true; do
        local -a sel_files
        sel_files=()
        print -r -- "" >&2
        print -r -- "${bd}选择会话 · @${agent_name}${rs}  ${gy}(回车 = 新建)${rs}" >&2
        print -r -- "  ${cy}[0]${rs} ${bd}+ 新建会话${rs}" >&2
        integer n=0
        local -a show_dates
        (( today_has )) && show_dates+=("$today")
        for (( i=1; i<=revealed && i<=${#older}; i++ )); do show_dates+=("${older[i]}"); done

        local dt f tm q label
        for dt in "${show_dates[@]}"; do
            if [[ "$dt" == "$today" ]]; then
                print -r -- "  ${gy}── 今天 $dt ──${rs}" >&2
            else
                print -r -- "  ${gy}── $dt ──${rs}" >&2
            fi
            while IFS= read -r f; do
                [[ -n "$f" ]] || continue
                (( n++ ))
                sel_files+=("$f")
                tm="$(_zsh_ai_chat_session_time "$f")"
                q="$(_zsh_ai_chat_truncate "$(_zsh_ai_chat_last_query "$f")" 50)"
                [[ -n "$q" ]] || q="${gy}(空会话)${rs}"
                print -r -- "  ${cy}[$n]${rs} ${tm}  ${q}" >&2
            done < <(_zsh_ai_chat_session_files "$agent_id" "$dt")
        done

        local has_more=0
        (( revealed < ${#older} )) && has_more=1
        (( has_more )) && print -r -- "  ${cy}[m]${rs} ${ye}▾ 显示更早的会话${rs}" >&2

        local choice
        print -n -- "› " >&2
        if ! IFS= read -r choice; then print "" >&2; return 0; fi
        choice="${choice## }"; choice="${choice%% }"

        if [[ -z "$choice" || "$choice" == 0 ]]; then
            return 0
        elif [[ "$choice" == m && $has_more -eq 1 ]]; then
            (( revealed += 5 ))
            (( revealed > ${#older} )) && revealed=${#older}
            continue
        elif [[ "$choice" == <-> ]] && (( choice >= 1 && choice <= n )); then
            _zsh_ai_chat_chosen_file="${sel_files[choice]}"
            return 0
        fi
        print -r -- "${ye}无效选择,请重试${rs}" >&2
    done
}

# Load a session file into the caller's turn_roles/turn_contents/current_summary
# (rounds = number of user turns loaded). System lines are ignored (the agent
# prompt is the source of truth, read live from the agent file).
_zsh_ai_chat_load_session() {
    emulate -L zsh
    local file="$1"
    turn_roles=(); turn_contents=(); current_summary=""; rounds=0
    [[ -r "$file" ]] || return 0
    local role content
    while IFS=$'\t' read -r role content; do
        case "$role" in
            summary) current_summary="$content" ;;
            user)    turn_roles+=("user");      turn_contents+=("$content"); (( rounds++ )) ;;
            assistant) turn_roles+=("assistant"); turn_contents+=("$content") ;;
        esac
    done < <(perl -ne '
        my %f;
        if (/"role":"((?:[^"\\]|\\.)*)"/) { $f{role} = $1; }
        if (/"content":"((?:[^"\\]|\\.)*)"/) {
            my $v = $1;
            # Encode real newlines/tabs to sentinels so each record stays on one
            # line with a single real-tab delimiter for the zsh read below.
            $v =~ s/\\n/\x01/g; $v =~ s/\\t/\x02/g; $v =~ s/\\r//g;
            $v =~ s/\\"/"/g; $v =~ s/\\\\/\\/g;
            $f{content} = $v;
        }
        print "$f{role}\t$f{content}\n" if defined $f{role};
    ' "$file" 2>/dev/null)
    # Restore real newlines/tabs (encoded above to survive the TSV read).
    # NOTE: in zsh the replacement half of ${//} does NOT re-expand $'\n', so we
    # must substitute variables that already hold the real characters.
    local nl=$'\n' tb=$'\t'
    integer i
    for (( i=1; i<=${#turn_contents[@]}; i++ )); do
        turn_contents[i]="${turn_contents[i]//$'\x01'/$nl}"
        turn_contents[i]="${turn_contents[i]//$'\x02'/$tb}"
    done
    current_summary="${current_summary//$'\x01'/$nl}"
    current_summary="${current_summary//$'\x02'/$tb}"
}

# --- compression ------------------------------------------------------------

_zsh_ai_chat_compress_prompt() {
    cat <<'EOF'
你是一个对话上下文压缩器。下面是一段多轮对话(用户与助手)。请把它压缩成一段简洁的中文上下文摘要,要求:
- 保留关键事实、用户的目标与偏好、已达成的结论、尚未解决的问题。
- 不要寒暄,不要逐句复述,不要编造对话里没有的信息。
- 只输出摘要正文本身,不要任何前言或标题。
EOF
}

# Compress the live conversation into one summary line. Snapshots the current
# session file first, then rewrites it as (system line + summary line). On
# success sets ZSH_AI_CHAT_NEW_SUMMARY and prints a size report; returns 1 on
# failure (leaving the session untouched). Reads caller scope: agent_id,
# agent_prompt, session_file, current_summary, turn_roles, turn_contents, rounds.
_zsh_ai_chat_compress() {
    emulate -L zsh
    ZSH_AI_CHAT_NEW_SUMMARY=""
    local gy=$'\e[90m' gr=$'\e[32m' ye=$'\e[33m' rs=$'\e[0m'

    # Render the live turns (and any prior summary) as plain text for the model.
    local rendered="" i
    [[ -n "$current_summary" ]] && rendered+="[已有摘要]"$'\n'"$current_summary"$'\n\n'
    for (( i=1; i<=${#turn_roles[@]}; i++ )); do
        if [[ "${turn_roles[i]}" == user ]]; then
            rendered+="用户: ${turn_contents[i]}"$'\n'
        else
            rendered+="助手: ${turn_contents[i]}"$'\n'
        fi
    done
    if [[ -z "$rendered" ]]; then
        return 1
    fi

    print -r -- "${gy}  正在压缩对话上下文…${rs}" >&2
    local ZSH_AI_CHAT_MAX_TOKENS="${ZSH_AI_CHAT_COMPRESS_MAX_TOKENS:-2048}"
    _zsh_ai_chat_oneshot "$(_zsh_ai_chat_compress_prompt)" "$rendered"
    local summary_rc=$? summary="$ZSH_AI_CHAT_REPLY"
    if (( summary_rc != 0 )) || [[ -z "$summary" ]]; then
        print -r -- "${ye}  压缩失败,保留原始对话继续。${rs}" >&2
        [[ -n "$ZSH_AI_CHAT_ERR" ]] && print -r -- "${ye}  ($ZSH_AI_CHAT_ERR)${rs}" >&2
        return 1
    fi

    # Stats BEFORE the rewrite.
    integer old_lines=0 old_bytes=0
    [[ -r "$session_file" ]] && { old_lines=$(wc -l < "$session_file"); old_bytes=$(wc -c < "$session_file"); }

    # Snapshot the pre-compression file: raw-<session-sid>-<compress-sid>.jsonl
    local sdir="${session_file:h}"
    local sbase="${session_file:t}"; sbase="${sbase#session-}"; sbase="${sbase%.jsonl}"
    local rawfile="$sdir/raw-${sbase}-$(_zsh_ai_chat_sid).jsonl"
    ( umask 077; cp "$session_file" "$rawfile" ) 2>/dev/null

    # Rewrite the session: system (agent prompt) + one summary line. Atomic.
    local ts="$(date +%Y-%m-%dT%H:%M:%S%z)"
    local sys_line="{\"ts\":\"$(_zsh_ai_escape_json "$ts")\",\"role\":\"system\",\"content\":\"$(_zsh_ai_escape_json "$agent_prompt")\"}"
    local sum_line="{\"ts\":\"$(_zsh_ai_escape_json "$ts")\",\"role\":\"summary\",\"content\":\"$(_zsh_ai_escape_json "$summary")\"}"
    local tmp="${session_file}.tmp.$$"
    (
        umask 077
        print -r -- "$sys_line" > "$tmp"
        print -r -- "$sum_line" >> "$tmp"
    ) 2>/dev/null
    if [[ ! -s "$tmp" ]] || ! mv -f "$tmp" "$session_file" 2>/dev/null; then
        rm -f "$tmp" "$rawfile" 2>/dev/null
        print -r -- "${ye}  压缩写入失败,保留原始对话继续。${rs}" >&2
        return 1
    fi

    integer new_lines=$(wc -l < "$session_file") new_bytes=$(wc -c < "$session_file")
    ZSH_AI_CHAT_NEW_SUMMARY="$summary"
    print -r -- "${gr}  ✓ 已压缩  ${rounds} 轮 / ${old_lines} 行 / $(_zsh_ai_human_size $old_bytes)  →  ${new_lines} 行 / $(_zsh_ai_human_size $new_bytes)${rs}" >&2
    print -r -- "${gy}    备份: ${rawfile:t}${rs}" >&2
    return 0
}

# --- framed transcript UI ---------------------------------------------------

_zsh_ai_chat_top() {
    emulate -L zsh
    setopt local_options multibyte
    local label="$1"
    integer cols=${COLUMNS:-80}; (( cols < 40 )) && cols=80; (( cols > 100 )) && cols=100
    local txt="╭─ $label "
    integer w=$(_zsh_ai_display_width "$txt") i
    local dash=""
    for (( i=w; i<cols-1; i++ )); do dash+="─"; done
    print -r -- $'\e[90m'"${txt}${dash}╮"$'\e[0m'
}

_zsh_ai_chat_bottom() {
    emulate -L zsh
    integer cols=${COLUMNS:-80} i; (( cols < 40 )) && cols=80; (( cols > 100 )) && cols=100
    local dash=""
    for (( i=0; i<cols-2; i++ )); do dash+="─"; done
    print -r -- $'\e[90m'"╰${dash}╯"$'\e[0m'
}

# Print text with a left frame bar, one label on the first line.
_zsh_ai_chat_say() {
    emulate -L zsh
    local color="$1" label="$2" text="$3" line bar=$'\e[90m│\e[0m '
    local rs=$'\e[0m' prefix="$label"
    while IFS= read -r line; do
        print -r -- "${bar}${color}${prefix}${line}${rs}"
        prefix=""
    done <<< "$text"
}

# --- entry point ------------------------------------------------------------

zsh-ai-chat() {
    emulate -L zsh

    if ! _zsh_ai_chat_enabled; then
        print -r -- "zsh-ai-chat: 需要先设置 ZSH_AI_LOG_DIR(会话要落盘)。" >&2
        return 1
    fi

    local agent_id="$1"; shift 2>/dev/null
    local first_msg="$(_zsh_ai_trim "$*")"

    if [[ -z "$agent_id" ]]; then
        print -r -- "用法: zsh-ai-chat <agent-id> [首条消息]" >&2
        local -a ids; ids=( ${(f)"$(_zsh_ai_agent_ids)"} )
        if (( ${#ids} )); then
            print -r -- "可用 agent:" >&2
            local id
            for id in "${ids[@]}"; do print -r -- "  @$id  ($(_zsh_ai_agent_name "$id"))" >&2; done
        else
            print -r -- "尚未定义任何 agent。在 $(_zsh_ai_agents_dir)/ 下放置 <id>.json,内容 {\"id\":..,\"name\":..,\"prompt\":..}" >&2
        fi
        return 1
    fi

    if ! _zsh_ai_agent_exists "$agent_id"; then
        print -r -- "zsh-ai-chat: 找不到 agent '@$agent_id'(应有文件 $(_zsh_ai_agent_file "$agent_id"))" >&2
        return 1
    fi

    local agent_name="$(_zsh_ai_agent_name "$agent_id")"
    local agent_prompt="$(_zsh_ai_agent_prompt "$agent_id")"
    if [[ -z "$agent_prompt" ]]; then
        print -r -- "zsh-ai-chat: agent '@$agent_id' 的 prompt 为空。" >&2
        return 1
    fi

    # Pick or create a session.
    local current_summary="" session_file=""
    local -a turn_roles turn_contents
    integer rounds=0
    _zsh_ai_chat_select_session "$agent_id" "$agent_name"
    if [[ -n "$_zsh_ai_chat_chosen_file" ]]; then
        session_file="$_zsh_ai_chat_chosen_file"
        _zsh_ai_chat_load_session "$session_file"
        print -r -- "已载入会话 ${session_file:t}(${rounds} 轮)" >&2
    else
        local date_str="$(date +%Y-%m-%d)"
        local sdir="$ZSH_AI_LOG_DIR/sessions/$agent_id/$date_str"
        [[ -d "$sdir" ]] || ( umask 077; mkdir -p "$sdir" ) 2>/dev/null
        if [[ ! -d "$sdir" ]]; then
            print -r -- "zsh-ai-chat: 无法创建会话目录 $sdir" >&2
            return 1
        fi
        session_file="$sdir/session-$(_zsh_ai_chat_sid).jsonl"
        _zsh_ai_chat_append_line "$session_file" system "$agent_prompt"
    fi

    integer max_rounds="${ZSH_AI_CHAT_MAX_ROUNDS:-10}"
    [[ "$max_rounds" == <-> ]] && (( max_rounds > 0 )) || max_rounds=10

    _zsh_ai_chat_top "💬 @${agent_name}"
    print -r -- $'\e[90m│\e[0m '$'\e[90m输入消息开始对话;输入 quit 退出。\e[0m'

    local cyu=$'\e[36m' grn=$'\e[32m' gy=$'\e[90m' rs=$'\e[0m'
    local line reply effective_system

    while true; do
        if [[ -n "$first_msg" ]]; then
            line="$first_msg"; first_msg=""
            _zsh_ai_chat_say "$cyu" "你 › " "$line"
        else
            print -n -- "${gy}│${rs} ${cyu}你 › ${rs}"
            if ! IFS= read -r line; then print ""; break; fi
        fi
        [[ "$line" == quit || "$line" == ":q" || "$line" == exit ]] && break
        line="$(_zsh_ai_trim "$line")"
        [[ -z "$line" ]] && continue

        # Append the user turn (memory + disk) and build the request.
        turn_roles+=("user"); turn_contents+=("$line")
        _zsh_ai_chat_append_line "$session_file" user "$line"

        effective_system="$agent_prompt"
        [[ -n "$current_summary" ]] && effective_system+=$'\n\n[以下是之前对话的摘要,用于延续上下文]\n'"$current_summary"

        print -r -- "${gy}│ ${agent_name} 思考中…${rs}"
        _zsh_ai_chat_complete
        local rc=$?; reply="$ZSH_AI_CHAT_REPLY"
        if (( rc != 0 )) || [[ -z "$reply" ]]; then
            _zsh_ai_chat_say $'\e[31m' "⚠ " "请求失败: ${ZSH_AI_CHAT_ERR:-未知错误}"
            # Roll back the unanswered user turn so the next retry isn't doubled.
            turn_roles[-1]=(); turn_contents[-1]=()
            continue
        fi

        _zsh_ai_chat_say "$grn" "${agent_name} › " "$reply"
        turn_roles+=("assistant"); turn_contents+=("$reply")
        _zsh_ai_chat_append_line "$session_file" assistant "$reply"
        (( rounds++ ))

        # Every max_rounds rounds, offer to compress.
        if (( rounds >= max_rounds )); then
            print -n -- "${gy}│${rs} 已达 ${rounds} 轮,压缩历史后继续?[y/N] "
            local ans
            if IFS= read -r ans && [[ "${ans:l}" == y* ]]; then
                if _zsh_ai_chat_compress; then
                    current_summary="$ZSH_AI_CHAT_NEW_SUMMARY"
                    turn_roles=(); turn_contents=(); rounds=0
                fi
            fi
        fi
    done

    _zsh_ai_chat_bottom
    print -r -- "${gy}会话已保存: ${session_file}${rs}" >&2
    return 0
}
