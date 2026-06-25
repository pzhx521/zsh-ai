#!/usr/bin/env zsh

# Request logging for zsh-ai.
#
# When ZSH_AI_LOG_DIR is set, every request to the model is appended as one JSON
# line to $ZSH_AI_LOG_DIR/YYYY-MM-DD.jsonl (local date). Records are appended in
# chronological order. Multiple terminals may write the same file concurrently,
# so appends are serialized with a lock: flock(1) when available (Linux), with a
# portable mkdir-based spinlock fallback (e.g. macOS, which ships no flock).
#
# API keys are never logged. The system prompt and full request body are not
# logged either - only the user's query and the parsed result.

# Append a single pre-built line to a file under a cross-process lock.
# Usage: _zsh_ai_log_append <file> <line>
_zsh_ai_log_append() {
    emulate -L zsh
    local file="$1" line="$2"

    if command -v flock >/dev/null 2>&1; then
        # Lock on a sibling .lock file via fd 9; flock releases it when the
        # block's redirection closes. -w 5 bounds the wait so we never hang.
        # umask 077 (in a subshell, so it doesn't leak) makes the data and lock
        # files mode 600 - the log can contain commands the user typed.
        (
            umask 077
            {
                if flock -w 5 9; then
                    print -r -- "$line" >> "$file"
                fi
            } 9>>"${file}.lock"
        )
        return 0
    fi

    # Portable fallback: mkdir is atomic. Spin briefly, then give up the lock and
    # append anyway (a single short line is almost always an atomic O_APPEND
    # write, so this is safe-enough as a last resort and never blocks forever).
    local lockdir="${file}.lockd"
    (
        umask 077
        integer got=0 i
        for (( i=0; i<50; i++ )); do
            if mkdir "$lockdir" 2>/dev/null; then
                got=1
                print -r -- "$line" >> "$file"
                rmdir "$lockdir" 2>/dev/null
                break
            fi
            sleep 0.1
        done
        (( got )) || print -r -- "$line" >> "$file"
    )
    return 0
}

# Build and append one JSON log line for a request.
# Usage: _zsh_ai_log_request <query> <raw_response> <rc> <ok>
#   ok=1 means a usable command was returned; ok=0 means error/empty.
_zsh_ai_log_request() {
    emulate -L zsh
    _zsh_ai_log_enabled || return 0

    local query="$1" raw="$2" rc="$3" ok="$4"

    local dir="$ZSH_AI_LOG_DIR"
    # Create the log dir as 700 (subshell umask, so it doesn't leak).
    [[ -d "$dir" ]] || ( umask 077; mkdir -p "$dir" ) 2>/dev/null
    [[ -d "$dir" ]] || return 0
    local file="$dir/$(date +%Y-%m-%d).jsonl"
    local ts="$(date +%Y-%m-%dT%H:%M:%S%z)"

    local provider="$ZSH_AI_PROVIDER"
    local model="$(_zsh_ai_current_model)"
    local os="$(_zsh_ai_build_context)"; os="${os#OS: }"
    local http_status="${ZSH_AI_LAST_STATUS:-}"

    local command_str="" explanation="" params="" risk="" error=""
    local ok_json="false"
    if [[ "$ok" == "1" ]]; then
        ok_json="true"
        command_str="$(_zsh_ai_json_field "$raw" command)"
        [[ -z "$command_str" ]] && command_str="$(_zsh_ai_sanitize "$raw")"
        explanation="$(_zsh_ai_json_field "$raw" explanation)"
        params="$(_zsh_ai_json_field "$raw" parameters)"
        if (( ${+functions[_zsh_ai_risk_level]} )) && _zsh_ai_safety_enabled; then
            risk="$(_zsh_ai_risk_level "$command_str")"
        fi
    else
        error="$(_zsh_ai_sanitize "$raw")"
    fi

    local line
    line="{\"ts\":\"$(_zsh_ai_escape_json "$ts")\""
    line+=",\"provider\":\"$(_zsh_ai_escape_json "$provider")\""
    line+=",\"model\":\"$(_zsh_ai_escape_json "$model")\""
    line+=",\"os\":\"$(_zsh_ai_escape_json "$os")\""
    line+=",\"query\":\"$(_zsh_ai_escape_json "$query")\""
    line+=",\"ok\":${ok_json}"
    line+=",\"status\":\"$(_zsh_ai_escape_json "$http_status")\""
    line+=",\"command\":\"$(_zsh_ai_escape_json "$command_str")\""
    line+=",\"explanation\":\"$(_zsh_ai_escape_json "$explanation")\""
    line+=",\"parameters\":\"$(_zsh_ai_escape_json "$params")\""
    line+=",\"risk\":\"$(_zsh_ai_escape_json "$risk")\""
    line+=",\"error\":\"$(_zsh_ai_escape_json "$error")\"}"

    _zsh_ai_log_append "$file" "$line"
}
