#!/usr/bin/env zsh

# Utility functions for zsh-ai

# Function to get the standardized system prompt for all providers
_zsh_ai_get_system_prompt() {
    local context="$1"
    local base_prompt="You are a zsh command generator. Given the user's natural language request, return a single JSON object describing one zsh command.\n\nIMPORTANT RULES:\n1. Return ONLY a raw JSON object - no markdown, no code fences, no text outside the JSON\n2. The JSON must contain exactly these keys: \"command\", \"explanation\", \"parameters\"\n3. \"command\": the raw, runnable zsh command on a single line - no backticks, no leading \$ prompt\n4. \"explanation\": at most 1-2 short lines describing what the command does\n5. \"parameters\": at most 1-2 short lines explaining the key flags/arguments (use an empty string if there are none)\n6. Reply in the same language as the request (e.g. a Chinese request gets a Chinese explanation and parameters)\n7. In \"command\", quote arguments containing spaces or special characters with single quotes; use double quotes only when variable expansion is needed; escape special characters properly\n\nExamples:\nRequest: delete log files older than 7 days\n{\"command\":\"find . -name '*.log' -mtime +7 -delete\",\"explanation\":\"Find and delete .log files not modified in the last 7 days.\",\"parameters\":\"-mtime +7 = older than 7 days; -delete removes each match.\"}\n\nRequest: show the current user\n{\"command\":\"echo \\\"Current user: \$USER\\\"\",\"explanation\":\"Print the current username.\",\"parameters\":\"\$USER expands to the logged-in user.\"}"
    
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

# Extract a top-level string field from the model's JSON response.
# Prefers jq when available, falls back to perl (a required dependency).
# Returns an empty string when the field is missing or the input is not JSON.
_zsh_ai_json_field() {
    emulate -L zsh
    local json="$1" field="$2"

    # Strip code fences and stray carriage returns the model may add
    json="${json//$'\r'/}"
    json="${json#\`\`\`json}"
    json="${json#\`\`\`}"
    json="${json%\`\`\`}"

    if command -v jq >/dev/null 2>&1; then
        local out
        out="$(printf '%s' "$json" | jq -er --arg f "$field" '.[$f] // empty' 2>/dev/null)"
        if [[ $? -eq 0 ]]; then
            printf '%s' "$out"
            return 0
        fi
    fi

    # perl fallback: extract "field":"..." handling escaped characters
    FIELD="$field" perl -0777 -ne '
        my $f = quotemeta($ENV{FIELD});
        if (/"$f"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
            my $v = $1;
            $v =~ s/\\n/\n/g; $v =~ s/\\t/\t/g; $v =~ s/\\r//g;
            $v =~ s/\\"/"/g; $v =~ s/\\\\/\\/g;
            print $v;
        }
    ' <<< "$json"
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
        printf '%s' "$raw"
        return 0
    fi

    explanation="$(_zsh_ai_json_field "$raw" explanation)"
    params="$(_zsh_ai_json_field "$raw" parameters)"

    [[ -n "$explanation" ]] && print -P "%F{cyan}ℹ ${explanation}%f" >&2
    [[ -n "$params" ]] && print -P "%F{8}↳ ${params}%f" >&2

    printf '%s' "$command_str"
}

# Main query function that routes to the appropriate provider
_zsh_ai_query() {
    local query="$1"

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
    local cmd=$(_zsh_ai_query "$query")
    
    if [[ -n "$cmd" ]] && [[ "$cmd" != "Error:"* ]] && [[ "$cmd" != "API Error:"* ]]; then
        echo "$cmd"
        return 0
    else
        # Return error
        echo "$cmd"
        return 1
    fi
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
        # Parse the JSON response: prints explanation/parameters, returns the command
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
        # Put the command in the ZLE buffer (same as # method)
        print -z "$parsed_cmd"
    else
        # Show error with better visibility
        echo ""  # Blank line for spacing
        print -P "%F{red}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"
        print -P "%F{red}❌ Failed to generate command%f"
        if [[ -n "$cmd" ]]; then
            print -P "%F{red}$cmd%f"
        fi
        print -P "%F{red}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━%f"
        echo ""  # Blank line for spacing
        return 1
    fi
}
