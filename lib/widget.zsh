#!/usr/bin/env zsh

# ZLE widget and key binding for zsh-ai

# Custom widget to intercept Enter key
_zsh_ai_accept_line() {
    local trigger="${ZSH_AI_TRIGGER:-# }"
    local query=""
    local _zsh_ai_matched=0

    # Decide whether this line should be sent to the AI:
    #   1. it starts with the configured trigger (default "# "), or
    #   2. Chinese auto-detection is on and the line contains CJK characters.
    if [[ "$BUFFER" == "$trigger"* ]]; then
        _zsh_ai_matched=1
        query="${BUFFER#"$trigger"}"
    elif _zsh_ai_chinese_detect_enabled && [[ "$BUFFER" != *$'\n'* ]] && _zsh_ai_contains_cjk "$BUFFER"; then
        _zsh_ai_matched=1
        query="$BUFFER"
    fi

    if (( _zsh_ai_matched )); then
        # Multiline command detected - execute normally without AI processing
        if [[ "$BUFFER" == *$'\n'* ]]; then
            zle .accept-line
            return
        fi
        
        # Add a loading indicator with animation
        local saved_buffer="$BUFFER"
        
        # Animation frames - rotating dots
        local dots=("⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏")
        
        local frame=0
        
        # Create a temp file for the response
        local tmpfile=$(mktemp 2>/dev/null)
        if [[ -z "$tmpfile" ]]; then
            echo ""
            print -P "%F{red}❌ zsh-ai: 无法创建临时文件(检查 TMPDIR / 磁盘空间)%f"
            BUFFER="$saved_buffer"
            CURSOR=$#BUFFER
            zle reset-prompt
            return
        fi

        # Disable job control notifications
        setopt local_options no_monitor no_notify no_bg_nice
        
        # Start the API query in background using the shared function
        # Only redirect stdout to tmpfile, let stderr go to /dev/null to avoid mixing error output
        (_zsh_ai_execute_command "$query" > "$tmpfile" 2>/dev/null) &
        local pid=$!
        
        # Animate while waiting
        while kill -0 $pid 2>/dev/null; do
            BUFFER="$saved_buffer ${dots[$((frame % ${#dots[@]}))]}"
            zle redisplay
            ((frame++))
            # Use zsh's built-in sleep equivalent
            zle -R && sleep 0.1
        done
        
        # Reap the background job so it doesn't linger in the job table
        wait $pid 2>/dev/null
        local exit_code=$?

        # Get the response
        local cmd=$(cat "$tmpfile")
        rm -f "$tmpfile"
        
        if [[ $exit_code -eq 0 ]] && [[ -n "$cmd" ]] && [[ "$cmd" != "Error:"* ]] && [[ "$cmd" != "API Error:"* ]]; then
            # Parse the JSON response (falls back to raw text when not JSON)
            local command_str explanation params
            command_str="$(_zsh_ai_json_field "$cmd" command)"
            if [[ -z "$command_str" ]]; then
                command_str="$(_zsh_ai_sanitize "$cmd")"
            else
                explanation="$(_zsh_ai_json_field "$cmd" explanation)"
                params="$(_zsh_ai_json_field "$cmd" parameters)"
            fi

            # Classify the parsed command's risk (when safety is enabled)
            local risk="safe"
            _zsh_ai_safety_enabled && risk="$(_zsh_ai_risk_level "$command_str")"

            if [[ "${ZSH_AI_OUTPUT_MODE:l}" != "buffer" ]]; then
                # Box mode: show everything framed and leave the prompt EMPTY so
                # the command can never be run by accident.
                echo ""
                _zsh_ai_render_box "$command_str" "$explanation" "$params" "$risk"
                BUFFER=""
                CURSOR=0
            elif [[ "$risk" == "blocked" ]] && [[ "${ZSH_AI_BLACKLIST_ACTION:l}" != "warn" ]]; then
                # Buffer mode + blacklisted - refuse to place it in the buffer
                echo ""
                print -P "%F{red}⛔ zsh-ai 拦截了一条黑名单命令,已拒绝填入:%f"
                print -P "%F{red}   $command_str%f"
                echo ""
                BUFFER="$saved_buffer"
                CURSOR=$#BUFFER
                sleep 0.5
            else
                # Buffer mode: replace the buffer with the command (not executed)
                BUFFER="$command_str"
                CURSOR=$#BUFFER

                # Show the explanation and key parameters above the prompt
                if [[ -n "$explanation" ]]; then
                    echo ""
                    print -P "%F{cyan}ℹ ${explanation}%f"
                    [[ -n "$params" ]] && print -P "%F{8}↳ ${params}%f"
                fi

                if _zsh_ai_safety_enabled; then
                    # Color the whole command by risk level
                    local style="$(_zsh_ai_risk_color "$risk")"
                    [[ -n "$style" ]] && region_highlight=("0 ${#BUFFER} ${style}")

                    # Surface a short note for risky commands
                    if [[ "$risk" == "high" || "$risk" == "blocked" ]]; then
                        [[ -z "$explanation" ]] && echo ""
                        print -P "%F{red}$(_zsh_ai_risk_label "$risk")%f"
                    fi
                fi
            fi
        else
            # Show error - keep it visible
            echo ""  # New line for better visibility
            print -P "%F{red}❌ Failed to generate command%f"
            if [[ -n "$cmd" ]]; then
                # Use raw printing: the error/diagnostics may contain '%' or
                # multiple lines, which `print -P` would mis-interpret.
                print -r -- $'\e[31m'"$cmd"$'\e[0m'
            fi
            echo ""  # Extra line for readability

            # Restore original buffer so user can see what query failed
            BUFFER="$saved_buffer"
            CURSOR=$#BUFFER

            # Sleep briefly to ensure error is visible before prompt redraws
            sleep 0.5
        fi

        # Redraw the prompt
        zle reset-prompt
    else
        # Normal command - execute as usual
        zle .accept-line
    fi
}

# Create the widget and bind it
# Uses precmd hook to defer registration until ZLE is fully initialized
# This fixes the issue where zle -N fails silently during plugin sourcing
_zsh_ai_init_widget() {
    # Respect the toggle: when disabled, never intercept accept-line so the
    # inline trigger (default "# ") behaves like a normal shell comment.
    _zsh_ai_comment_hook_enabled || return

    _zsh_ai_do_init() {
        zle -N accept-line _zsh_ai_accept_line
        add-zsh-hook -d precmd _zsh_ai_do_init
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _zsh_ai_do_init
}
