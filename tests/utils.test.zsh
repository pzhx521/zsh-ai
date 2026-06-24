#!/usr/bin/env zsh

# Load test helper
source "${0:A:h}/test_helper.zsh"

# Load required modules
source "$PLUGIN_DIR/lib/config.zsh"
source "$PLUGIN_DIR/lib/context.zsh"
source "$PLUGIN_DIR/lib/providers/anthropic.zsh"
source "$PLUGIN_DIR/lib/providers/ollama.zsh"
source "$PLUGIN_DIR/lib/utils.zsh"

# Test functions

# _zsh_ai_query routing tests
test_routes_to_anthropic_provider() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock Anthropic query function
    _zsh_ai_query_anthropic() {
        echo "anthropic:$1"
    }
    
    local output
    output=$(_zsh_ai_query "test query")
    assert_equals "$output" "anthropic:test query"
    
    teardown_test_env
}

test_routes_to_ollama_provider() {
    setup_test_env
    export ZSH_AI_PROVIDER="ollama"
    
    # Mock Ollama check and query functions
    _zsh_ai_check_ollama() {
        return 0
    }
    
    _zsh_ai_query_ollama() {
        echo "ollama:$1"
    }
    
    local output
    output=$(_zsh_ai_query "test query")
    assert_equals "$output" "ollama:test query"
    
    teardown_test_env
}

test_checks_ollama_availability_before_querying() {
    setup_test_env
    export ZSH_AI_PROVIDER="ollama"
    export ZSH_AI_OLLAMA_URL="http://localhost:11434"
    
    # Mock Ollama check to fail
    _zsh_ai_check_ollama() {
        return 1
    }
    
    local output
    output=$(_zsh_ai_query "test query")
    local result=$?
    
    assert_equals "$result" "1"
    assert_contains "$output" "Ollama is not running"
    assert_contains "$output" "http://localhost:11434"
    assert_contains "$output" "ollama serve"
    
    teardown_test_env
}

# zsh-ai command tests
test_shows_usage_without_arguments() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    
    # Capture output through a subshell
    local output
    output=$(zsh-ai)
    local result=$?
    
    assert_equals "$result" "1"
    assert_contains "$output" "Usage: zsh-ai"
    assert_contains "$output" "Example:"
    assert_contains "$output" "Current provider: anthropic"
    
    teardown_test_env
}

test_shows_ollama_model_in_usage() {
    setup_test_env
    export ZSH_AI_PROVIDER="ollama"
    export ZSH_AI_OLLAMA_MODEL="llama3.2"
    
    # Capture output through a subshell
    local output
    output=$(zsh-ai)
    local result=$?
    
    assert_equals "$result" "1"
    assert_contains "$output" "Current provider: ollama"
    assert_contains "$output" "Ollama model: llama3.2"
    
    teardown_test_env
}

test_shows_command_without_executing() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock query function
    _zsh_ai_query() {
        echo "echo 'Hello World'"
    }
    
    # Track eval execution - should NOT be called
    local eval_called=0
    eval() {
        eval_called=1
    }
    
    # Mock print -z to capture buffer command
    local buffer_cmd=""
    print() {
        if [[ "$1" == "-z" ]]; then
            buffer_cmd="$2"
        else
            builtin print "$@"
        fi
    }
    
    zsh-ai "say hello" >/dev/null 2>&1
    
    # Should put command in buffer but NOT execute it
    assert_equals "$eval_called" "0"
    assert_equals "$buffer_cmd" "echo 'Hello World'"
    
    teardown_test_env
}

test_puts_command_in_buffer() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock query function
    _zsh_ai_query() {
        echo "ls -la"
    }
    
    # Mock print -z to capture buffer command
    local buffer_cmd=""
    print() {
        if [[ "$1" == "-z" ]]; then
            buffer_cmd="$2"
        else
            builtin print "$@"
        fi
    }
    
    zsh-ai "list files" >/dev/null 2>&1
    
    # Should put command in buffer
    assert_equals "$buffer_cmd" "ls -la"
    
    teardown_test_env
}

test_handles_api_errors_in_zsh_ai() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock query function to return error
    _zsh_ai_query() {
        echo "Error: API connection failed"
    }
    
    # Capture output with stderr
    local output
    output=$(zsh-ai "test query" 2>&1)
    local result=$?
    
    assert_equals "$result" "1"
    assert_contains "$output" "Failed to generate command"
    assert_contains "$output" "API connection failed"
    
    teardown_test_env
}

test_handles_empty_response_in_zsh_ai() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock query function to return empty
    _zsh_ai_query() {
        echo ""
    }
    
    # Capture output with stderr
    local output
    output=$(zsh-ai "test query" 2>&1)
    local result=$?
    
    assert_equals "$result" "1"
    assert_contains "$output" "Failed to generate command"
    
    teardown_test_env
}

test_combines_multiple_arguments() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock execute command function
    _zsh_ai_execute_command() {
        echo "find . -name '*.py'"
    }
    
    # Mock print -z to capture buffer command
    local buffer_cmd=""
    print() {
        if [[ "$1" == "-z" ]]; then
            buffer_cmd="$2"
        else
            builtin print "$@"
        fi
    }
    
    zsh-ai find all python files >/dev/null 2>&1
    
    # Should put command in buffer
    assert_equals "$buffer_cmd" "find . -name '*.py'"
    
    teardown_test_env
}

test_puts_generated_command_in_buffer() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock execute command function
    _zsh_ai_execute_command() {
        echo "ls -la"
    }
    
    # Mock print -z to capture buffer command
    local buffer_cmd=""
    print() {
        if [[ "$1" == "-z" ]]; then
            buffer_cmd="$2"
        else
            builtin print "$@"
        fi
    }
    
    zsh-ai "list files" >/dev/null 2>&1
    
    # Should put command in buffer
    assert_equals "$buffer_cmd" "ls -la"
    
    teardown_test_env
}

test_no_execution_happens() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock execute command function
    _zsh_ai_execute_command() {
        echo "pwd"
    }
    
    # Track eval execution - should NOT be called
    local eval_called=0
    eval() {
        eval_called=1
    }
    
    # Mock print -z to capture buffer command
    local buffer_cmd=""
    print() {
        if [[ "$1" == "-z" ]]; then
            buffer_cmd="$2"
        else
            builtin print "$@"
        fi
    }
    
    zsh-ai "show directory" >/dev/null 2>&1
    
    # Should NOT execute the command
    assert_equals "$eval_called" "0"
    # Should put command in buffer
    assert_equals "$buffer_cmd" "pwd"
    
    teardown_test_env
}

test_shows_loading_spinner() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    
    # Mock execute command function with delay to simulate API call
    _zsh_ai_execute_command() {
        sleep 0.3
        echo "ls -la"
    }
    
    # Mock print -z to capture buffer command
    local buffer_cmd=""
    print() {
        if [[ "$1" == "-z" ]]; then
            buffer_cmd="$2"
        else
            builtin print "$@"
        fi
    }
    
    zsh-ai "list files" >/dev/null 2>&1
    
    # Should put command in buffer
    assert_equals "$buffer_cmd" "ls -la"
    
    teardown_test_env
}

test_get_system_prompt_includes_all_rules() {
    setup_test_env

    local prompt=$(_zsh_ai_get_system_prompt "test context")

    # Check that all key parts of the JSON-output prompt are present
    assert_contains "$prompt" "zsh command generator"
    assert_contains "$prompt" "IMPORTANT RULES"
    assert_contains "$prompt" "raw JSON object"
    assert_contains "$prompt" '"command"'
    assert_contains "$prompt" '"explanation"'
    assert_contains "$prompt" '"parameters"'
    assert_contains "$prompt" "single quotes"
    assert_contains "$prompt" "double quotes"
    assert_contains "$prompt" "variable expansion"
    assert_contains "$prompt" "Examples:"
    assert_contains "$prompt" "Context:"
    assert_contains "$prompt" "test context"

    teardown_test_env
}

test_get_system_prompt_with_complex_context() {
    setup_test_env
    
    local complex_context=$'Current dir: /home/user\nGit branch: main\nProject: Node.js'
    local prompt=$(_zsh_ai_get_system_prompt "$complex_context")
    
    # Check that context is included at the end
    assert_contains "$prompt" "Context:"
    assert_contains "$prompt" "$complex_context"
    
    teardown_test_env
}

test_get_system_prompt_with_empty_context() {
    setup_test_env
    
    local prompt=$(_zsh_ai_get_system_prompt "")
    
    # Should still include the Context: header even if empty
    assert_contains "$prompt" "Context:"
    
    teardown_test_env
}

test_get_system_prompt_with_extension() {
    setup_test_env
    
    # Set custom prompt extension
    export ZSH_AI_PROMPT_EXTEND="Always prefer modern CLI tools. Use ripgrep instead of grep."
    
    local prompt=$(_zsh_ai_get_system_prompt "test context")
    
    # Check that core prompt is still present
    assert_contains "$prompt" "zsh command generator"
    assert_contains "$prompt" "IMPORTANT RULES"
    
    # Check that extension is included
    assert_contains "$prompt" "Always prefer modern CLI tools"
    assert_contains "$prompt" "Use ripgrep instead of grep"
    
    # Check that context is still at the end
    assert_contains "$prompt" "Context:"
    assert_contains "$prompt" "test context"
    
    # Check proper ordering - extension should be between rules and context
    local prompt_text="$prompt"
    if [[ "$prompt_text" =~ "IMPORTANT RULES.*Always prefer modern CLI tools.*Context:" ]]; then
        # Test passes - ordering is correct
        :
    else
        echo "Error: Prompt extension not in correct position"
        return 1
    fi
    
    teardown_test_env
}

test_get_system_prompt_without_extension() {
    setup_test_env
    
    # Ensure no extension is set
    unset ZSH_AI_PROMPT_EXTEND
    
    local prompt=$(_zsh_ai_get_system_prompt "test context")
    
    # Should work exactly as before when no extension is set
    assert_contains "$prompt" "zsh command generator"
    assert_contains "$prompt" "IMPORTANT RULES"
    assert_contains "$prompt" "Context:"
    assert_contains "$prompt" "test context"
    
    # Should not have extra newlines where extension would be
    local expected_pattern=$'parameters\":\"\$USER expands to the logged-in user.\"}\n\nContext:'
    assert_contains "$prompt" "$expected_pattern"

    teardown_test_env
}

test_get_system_prompt_with_multiline_extension() {
    setup_test_env
    
    # Set multi-line custom prompt extension
    export ZSH_AI_PROMPT_EXTEND="Additional rules:\n1. Prefer fd over find\n2. Use bat instead of cat\n3. Always use exa for ls commands"
    
    local prompt=$(_zsh_ai_get_system_prompt "test context")
    
    # Check that all lines of extension are included
    assert_contains "$prompt" "Additional rules:"
    assert_contains "$prompt" "1. Prefer fd over find"
    assert_contains "$prompt" "2. Use bat instead of cat"
    assert_contains "$prompt" "3. Always use exa for ls commands"
    
    teardown_test_env
}

test_get_system_prompt_with_empty_extension() {
    setup_test_env
    
    # Set empty extension (should behave same as unset)
    export ZSH_AI_PROMPT_EXTEND=""
    
    local prompt=$(_zsh_ai_get_system_prompt "test context")
    
    # Should work exactly as before when extension is empty
    assert_contains "$prompt" "zsh command generator"
    assert_contains "$prompt" "IMPORTANT RULES"
    assert_contains "$prompt" "Context:"
    assert_contains "$prompt" "test context"
    
    teardown_test_env
}

# JSON response parsing tests
test_json_field_extracts_command() {
    setup_test_env
    local j='{"command":"lsof -ti:8080 | xargs kill -9","explanation":"x","parameters":"y"}'
    assert_equals "$(_zsh_ai_json_field "$j" command)" "lsof -ti:8080 | xargs kill -9"
    teardown_test_env
}

test_json_field_extracts_explanation() {
    setup_test_env
    local j='{"command":"ls","explanation":"列出文件","parameters":""}'
    assert_equals "$(_zsh_ai_json_field "$j" explanation)" "列出文件"
    teardown_test_env
}

test_json_field_handles_code_fences() {
    setup_test_env
    local j=$'```json\n{"command":"pwd","explanation":"e","parameters":"p"}\n```'
    assert_equals "$(_zsh_ai_json_field "$j" command)" "pwd"
    teardown_test_env
}

test_json_field_handles_escaped_quotes() {
    setup_test_env
    local j='{"command":"echo \"hi $USER\"","explanation":"e","parameters":"p"}'
    assert_equals "$(_zsh_ai_json_field "$j" command)" 'echo "hi $USER"'
    teardown_test_env
}

test_json_field_empty_for_non_json() {
    setup_test_env
    assert_equals "$(_zsh_ai_json_field "ls -la" command)" ""
    teardown_test_env
}

test_render_response_returns_command_for_json() {
    setup_test_env
    local j='{"command":"git status","explanation":"e","parameters":"p"}'
    # explanation/params go to stderr; stdout is the bare command
    assert_equals "$(_zsh_ai_render_response "$j" 2>/dev/null)" "git status"
    teardown_test_env
}

test_render_response_passes_through_plain_text() {
    setup_test_env
    assert_equals "$(_zsh_ai_render_response "ls -la" 2>/dev/null)" "ls -la"
    teardown_test_env
}

test_box_mode_does_not_push_to_buffer() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="test-key"
    export ZSH_AI_OUTPUT_MODE="box"

    _zsh_ai_query() { printf '%s' '{"command":"ls -la","explanation":"列出","parameters":""}'; }

    # Capture any print -z; box mode must never push the command to the buffer
    local buffer_cmd="__none__"
    print() {
        if [[ "$1" == "-z" ]]; then buffer_cmd="$2"; fi
    }

    zsh-ai "list files" >/dev/null 2>&1

    assert_equals "$buffer_cmd" "__none__"

    teardown_test_env
}

test_display_width_counts_cjk_as_two() {
    setup_test_env
    assert_equals "$(_zsh_ai_display_width 'abc')" "3"
    assert_equals "$(_zsh_ai_display_width '中文')" "4"
    assert_equals "$(_zsh_ai_display_width '说明：')" "6"
    teardown_test_env
}

# Sanitization / error-detection tests
test_sanitize_strips_control_chars() {
    setup_test_env
    local dirty=$'ls\e[31mX\e[0m'
    local clean="$(_zsh_ai_sanitize "$dirty")"
    if [[ "$clean" == *$'\e'* ]]; then TEST_FAILED=1; fi
    assert_equals "$clean" "ls[31mX[0m"
    teardown_test_env
}

test_json_field_strips_escape_sequences() {
    setup_test_env
    local j=$'{"command":"ls\e[2J","explanation":"x","parameters":""}'
    local cmd="$(_zsh_ai_json_field "$j" command)"
    if [[ "$cmd" == *$'\e'* ]]; then TEST_FAILED=1; fi
    teardown_test_env
}

test_execute_command_detects_nonprefixed_error() {
    setup_test_env
    export ZSH_AI_PROVIDER="ollama"
    # Restore the real function in case an earlier test left a mock behind
    source "$PLUGIN_DIR/lib/utils.zsh"
    # Provider returns an error with a non-standard prefix AND a non-zero code
    _zsh_ai_query() { echo "Ollama Error: model not found"; return 1; }

    local output rc
    output=$(_zsh_ai_execute_command "list files")
    rc=$?

    # Must be reported as a failure, not treated as a runnable command
    assert_equals "$rc" "1"
    teardown_test_env
}

# HTTP diagnostics tests
test_redact_hides_url_key() {
    setup_test_env
    local out=$(_zsh_ai_redact "https://x/v1?key=AIzaSECRET&foo=1")
    assert_contains "$out" "key=***REDACTED***"
    assert_not_contains "$out" "AIzaSECRET"
    teardown_test_env
}

test_redact_hides_bearer_token() {
    setup_test_env
    local out=$(_zsh_ai_redact "Authorization: Bearer sk-TOPSECRET")
    assert_contains "$out" "***REDACTED***"
    assert_not_contains "$out" "sk-TOPSECRET"
    teardown_test_env
}

test_curl_captures_status_and_body() {
    setup_test_env
    # Fake curl emits a body plus the status sentinel that real `curl -w` adds
    curl() { printf '%s' '{"ok":true}'; printf '\nZSHAI_HTTP_STATUS:503'; return 0; }

    _zsh_ai_curl "https://api.test/v1" '{"q":1}' --header "Authorization: Bearer k"

    assert_equals "$ZSH_AI_LAST_STATUS" "503"
    assert_equals "$ZSH_AI_LAST_RESPONSE" '{"ok":true}'
    assert_equals "$ZSH_AI_LAST_REQUEST" '{"q":1}'
    unfunction curl
    teardown_test_env
}

test_curl_without_sentinel_keeps_body() {
    setup_test_env
    # Mocked curl (as in provider tests) returns body only, no sentinel
    curl() { printf '%s' '{"choices":[{"message":{"content":"ls"}}]}'; return 0; }

    _zsh_ai_curl "https://api.test/v1" '{"q":1}'

    # Body must be preserved untouched so provider parsing still works
    assert_equals "$ZSH_AI_LAST_RESPONSE" '{"choices":[{"message":{"content":"ls"}}]}'
    assert_equals "$ZSH_AI_LAST_STATUS" ""
    unfunction curl
    teardown_test_env
}

test_error_report_includes_diagnostics() {
    setup_test_env
    ZSH_AI_LAST_STATUS="429"
    ZSH_AI_LAST_URL="https://api.test/v1"
    ZSH_AI_LAST_REQUEST='{"model":"x"}'
    ZSH_AI_LAST_RESPONSE='{"error":{"message":"rate limited"}}'

    local out=$(_zsh_ai_error_report "API Error: rate limited")

    assert_contains "$out" "API Error: rate limited"
    assert_contains "$out" "429"
    assert_contains "$out" '{"model":"x"}'
    assert_contains "$out" "rate limited"
    teardown_test_env
}

# Run tests
echo "Running utils tests..."
run_test "Routes to Anthropic provider when configured" test_routes_to_anthropic_provider
run_test "Routes to Ollama provider when configured" test_routes_to_ollama_provider
run_test "Checks Ollama availability before querying" test_checks_ollama_availability_before_querying
run_test "Shows usage when called without arguments" test_shows_usage_without_arguments
run_test "Shows Ollama model in usage for Ollama provider" test_shows_ollama_model_in_usage
run_test "Shows command without executing" test_shows_command_without_executing
run_test "Puts command in buffer" test_puts_command_in_buffer
run_test "Handles API errors in zsh-ai command" test_handles_api_errors_in_zsh_ai
run_test "Handles empty response in zsh-ai command" test_handles_empty_response_in_zsh_ai
run_test "Combines multiple arguments in zsh-ai command" test_combines_multiple_arguments
run_test "Puts generated command in buffer" test_puts_generated_command_in_buffer
run_test "No execution happens" test_no_execution_happens
run_test "Shows loading spinner during command generation" test_shows_loading_spinner
run_test "System prompt includes all rules" test_get_system_prompt_includes_all_rules
run_test "System prompt handles complex context" test_get_system_prompt_with_complex_context
run_test "System prompt handles empty context" test_get_system_prompt_with_empty_context
run_test "System prompt includes custom extension when set" test_get_system_prompt_with_extension
run_test "System prompt works without extension" test_get_system_prompt_without_extension
run_test "System prompt handles multiline extension" test_get_system_prompt_with_multiline_extension
run_test "System prompt handles empty extension" test_get_system_prompt_with_empty_extension
run_test "JSON field extracts command" test_json_field_extracts_command
run_test "JSON field extracts explanation" test_json_field_extracts_explanation
run_test "JSON field handles code fences" test_json_field_handles_code_fences
run_test "JSON field handles escaped quotes" test_json_field_handles_escaped_quotes
run_test "JSON field empty for non-json" test_json_field_empty_for_non_json
run_test "Render response returns command for json" test_render_response_returns_command_for_json
run_test "Render response passes through plain text" test_render_response_passes_through_plain_text
run_test "Box mode does not push to buffer" test_box_mode_does_not_push_to_buffer
run_test "Display width counts CJK as two" test_display_width_counts_cjk_as_two
run_test "Sanitize strips control chars" test_sanitize_strips_control_chars
run_test "JSON field strips escape sequences" test_json_field_strips_escape_sequences
run_test "Execute command detects non-prefixed error" test_execute_command_detects_nonprefixed_error
run_test "Redact hides URL key" test_redact_hides_url_key
run_test "Redact hides bearer token" test_redact_hides_bearer_token
run_test "Curl captures status and body" test_curl_captures_status_and_body
run_test "Curl without sentinel keeps body" test_curl_without_sentinel_keeps_body
run_test "Error report includes diagnostics" test_error_report_includes_diagnostics
finish_tests
