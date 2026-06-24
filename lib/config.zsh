#!/usr/bin/env zsh

# Configuration and validation for zsh-ai

# Set default values for configuration
: ${ZSH_AI_PROVIDER:="anthropic"}  # Default to anthropic for backwards compatibility
: ${ZSH_AI_OLLAMA_MODEL:="llama3.2"}  # Popular fast model
: ${ZSH_AI_OLLAMA_URL:="http://localhost:11434"}  # Default Ollama URL
: ${ZSH_AI_GEMINI_MODEL:="gemini-2.5-flash"}  # Fast Gemini 2.5 model
: ${ZSH_AI_OPENAI_MODEL:="gpt-5.4-mini"}  # Default to GPT-5.4 mini (gpt-5-mini is deprecated)
: ${ZSH_AI_OPENAI_URL:="https://api.openai.com/v1/chat/completions"}  # Default to OpenAI
: ${ZSH_AI_QWEN_MODEL:="qwen-flash"}  # Default to qwen-flash (fast, low-cost Qwen3 tier)
: ${ZSH_AI_QWEN_URL:="https://dashscope.aliyuncs.com/compatible-mode/v1/chat/completions"}  # Default to Qwen API
: ${ZSH_AI_ANTHROPIC_MODEL:="claude-haiku-4-5"}  # Default Anthropic model
: ${ZSH_AI_ANTHROPIC_URL:="https://api.anthropic.com/v1/messages"}  # Default Anthropic URL
: ${ZSH_AI_GROK_MODEL:="grok-4.3"}  # Default Grok model (provider sends reasoning_effort=none for speed)
: ${ZSH_AI_GROK_URL:="https://api.x.ai/v1/chat/completions"}  # Default Grok URL
: ${ZSH_AI_MISTRAL_MODEL:="mistral-small-latest"}  # Default Mistral model
: ${ZSH_AI_MISTRAL_URL:="https://api.mistral.ai/v1/chat/completions"}  # Default Mistral URL

# Inline trigger configuration
: ${ZSH_AI_COMMENT_HOOK:="true"}  # Set to false/off/no/0 to disable the inline trigger widget entirely
: ${ZSH_AI_TRIGGER:="# "}  # Prompt prefix that triggers AI (e.g. ",," instead of "# ")

# Return 0 if the inline trigger widget should be enabled, 1 otherwise
_zsh_ai_comment_hook_enabled() {
    case "${ZSH_AI_COMMENT_HOOK:l}" in
        false|off|no|0|disabled) return 1 ;;
        *) return 0 ;;
    esac
}

# Debugging ------------------------------------------------------------------
# When a request fails, the HTTP status code, redacted endpoint, request body
# and raw response are always shown to help troubleshoot. With ZSH_AI_DEBUG=true
# every request/response is also appended to ZSH_AI_DEBUG_LOG.
: ${ZSH_AI_DEBUG:="false"}
: ${ZSH_AI_DEBUG_LOG:="${HOME}/.zsh-ai-debug.log"}

_zsh_ai_debug_enabled() {
    case "${ZSH_AI_DEBUG:l}" in
        true|on|yes|1|enabled) return 0 ;;
        *) return 1 ;;
    esac
}

# Output mode ----------------------------------------------------------------
# box    = show the command + explanation + parameters inside a framed box and
#          leave the input line EMPTY (you copy/retype to run -> avoids misfires)
# buffer = paste the command into the editable prompt for you to confirm/run
: ${ZSH_AI_OUTPUT_MODE:="box"}

# Safety configuration -------------------------------------------------------
: ${ZSH_AI_SAFETY:="true"}            # Master toggle for blacklist + risk coloring
: ${ZSH_AI_BLACKLIST_ACTION:="block"} # block = refuse to fill buffer; warn = fill but flag in red

# Chinese / CJK auto-detection -----------------------------------------------
# When enabled, a line containing CJK characters is routed to the AI even
# without the "# " trigger. Disable if you frequently run commands that embed
# Chinese literals (e.g. echo 你好) and want them executed verbatim.
: ${ZSH_AI_CHINESE_DETECT:="true"}

# Risk-level colors (zsh highlight specs used for region_highlight) ----------
: ${ZSH_AI_COLOR_BLOCKED:="fg=white,bold"}
: ${ZSH_AI_COLOR_HIGH:="fg=red,bold"}
: ${ZSH_AI_COLOR_MEDIUM:="fg=yellow"}
: ${ZSH_AI_COLOR_SAFE:="fg=green"}

# Optional user-defined pattern arrays (POSIX ERE), checked in addition to the
# built-in defaults in lib/safety.zsh:
#   ZSH_AI_BLACKLIST_PATTERNS   - extra patterns treated as "blocked"
#   ZSH_AI_HIGH_RISK_PATTERNS   - extra patterns treated as "high" risk
#   ZSH_AI_MEDIUM_RISK_PATTERNS - extra patterns treated as "medium" risk

# Return 0 if safety (blacklist + risk coloring) is enabled, 1 otherwise
_zsh_ai_safety_enabled() {
    case "${ZSH_AI_SAFETY:l}" in
        false|off|no|0|disabled) return 1 ;;
        *) return 0 ;;
    esac
}

# Return 0 if Chinese/CJK auto-detection is enabled, 1 otherwise
_zsh_ai_chinese_detect_enabled() {
    case "${ZSH_AI_CHINESE_DETECT:l}" in
        false|off|no|0|disabled) return 1 ;;
        *) return 0 ;;
    esac
}

# Optional: Extend the system prompt with custom instructions
# ZSH_AI_PROMPT_EXTEND - Add custom instructions to the AI prompt without replacing the core prompt
# Example: export ZSH_AI_PROMPT_EXTEND="Always prefer ripgrep (rg) over grep. Use modern CLI tools when available."

# Provider validation
_zsh_ai_validate_config() {
    if [[ "$ZSH_AI_PROVIDER" != "anthropic" ]] && [[ "$ZSH_AI_PROVIDER" != "ollama" ]] && [[ "$ZSH_AI_PROVIDER" != "gemini" ]] && [[ "$ZSH_AI_PROVIDER" != "qwen" ]] && [[ "$ZSH_AI_PROVIDER" != "openai" ]] && [[ "$ZSH_AI_PROVIDER" != "grok" ]] && [[ "$ZSH_AI_PROVIDER" != "mistral" ]]; then
        echo "zsh-ai: Error: Invalid provider '$ZSH_AI_PROVIDER'. Use 'anthropic', 'ollama', 'gemini', 'openai', 'qwen', 'grok', or 'mistral'."
        return 1
    fi

    # Check requirements based on provider
    if [[ "$ZSH_AI_PROVIDER" == "anthropic" ]]; then
        if [[ -z "$ANTHROPIC_API_KEY" ]]; then
            echo "zsh-ai: Warning: ANTHROPIC_API_KEY not set. Plugin will not function."
            echo "zsh-ai: Set ANTHROPIC_API_KEY or use ZSH_AI_PROVIDER=ollama for local models."
            return 1
        fi
    elif [[ "$ZSH_AI_PROVIDER" == "gemini" ]]; then
        if [[ -z "$GEMINI_API_KEY" ]]; then
            echo "zsh-ai: Warning: GEMINI_API_KEY not set. Plugin will not function."
            echo "zsh-ai: Set GEMINI_API_KEY or use ZSH_AI_PROVIDER=ollama for local models."
            return 1
        fi
    elif [[ "$ZSH_AI_PROVIDER" == "openai" ]]; then
        # Only require API key when using the default OpenAI URL
        # Custom URLs (local servers, proxies) may not need authentication
        if [[ -z "$OPENAI_API_KEY" && -z "$ZSH_AI_OPENAI_API_KEY" && "$ZSH_AI_OPENAI_URL" == "https://api.openai.com/v1/chat/completions" ]]; then
            echo "zsh-ai: Warning: OPENAI_API_KEY not set. Plugin will not function."
            echo "zsh-ai: Set OPENAI_API_KEY or use ZSH_AI_PROVIDER=ollama for local models."
            return 1
        fi
    elif [[ "$ZSH_AI_PROVIDER" == "qwen" ]]; then
        if [[ -z "$QWEN_API_KEY" ]]; then
            echo "zsh-ai: Warning: QWEN_API_KEY not set. Plugin will not function."
            echo "zsh-ai: Set QWEN_API_KEY or use ZSH_AI_PROVIDER=ollama for local models."
            return 1
        fi
    elif [[ "$ZSH_AI_PROVIDER" == "grok" ]]; then
        if [[ -z "$XAI_API_KEY" ]]; then
            echo "zsh-ai: Warning: XAI_API_KEY not set. Plugin will not function."
            echo "zsh-ai: Set XAI_API_KEY or use ZSH_AI_PROVIDER=ollama for local models."
            return 1
        fi
    elif [[ "$ZSH_AI_PROVIDER" == "mistral" ]]; then
        if [[ -z "$MISTRAL_API_KEY" ]]; then
            echo "zsh-ai: Warning: MISTRAL_API_KEY not set. Plugin will not function."
            echo "zsh-ai: Set MISTRAL_API_KEY or use ZSH_AI_PROVIDER=ollama for local models."
            return 1
        fi
    fi

    return 0
}
