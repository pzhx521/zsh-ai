#!/usr/bin/env zsh

# Load test helper
source "${0:A:h}/test_helper.zsh"

# Load modules needed for logging
source "$PLUGIN_DIR/lib/config.zsh"
source "$PLUGIN_DIR/lib/safety.zsh"
source "$PLUGIN_DIR/lib/context.zsh"
source "$PLUGIN_DIR/lib/utils.zsh"
source "$PLUGIN_DIR/lib/logging.zsh"

_log_file_today() { echo "$ZSH_AI_LOG_DIR/$(date +%Y-%m-%d).jsonl"; }

# --- _zsh_ai_log_enabled ----------------------------------------------------
test_log_disabled_when_dir_unset() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR=""
    export ZSH_AI_PROVIDER="openai"
    _zsh_ai_log_request "hi" '{"command":"ls"}' 0 1
    # No file should be created anywhere under TEST_DIR
    local count=$(find "$TEST_DIR" -name '*.jsonl' 2>/dev/null | wc -l | tr -d ' ')
    assert_equals "$count" "0"
    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

# --- successful request -----------------------------------------------------
test_logs_success_line() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"
    export ZSH_AI_OPENAI_MODEL="deepseek-v4-flash"
    ZSH_AI_LAST_STATUS=200

    _zsh_ai_log_request "找出占用8080端口的进程" '{"command":"lsof -ti:8080","explanation":"e","parameters":"p"}' 0 1

    local line=$(cat "$(_log_file_today)")
    assert_contains "$line" '"ok":true'
    assert_contains "$line" '"provider":"openai"'
    assert_contains "$line" '"model":"deepseek-v4-flash"'
    assert_contains "$line" '"query":"找出占用8080端口的进程"'
    assert_contains "$line" '"command":"lsof -ti:8080"'
    assert_contains "$line" '"status":"200"'

    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER ZSH_AI_OPENAI_MODEL
    teardown_test_env
}

# --- failed request ---------------------------------------------------------
test_logs_failure_line() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="anthropic"
    ZSH_AI_LAST_STATUS=401

    _zsh_ai_log_request "随便写点啥" "API Error: invalid x-api-key" 1 0

    local line=$(cat "$(_log_file_today)")
    assert_contains "$line" '"ok":false'
    assert_contains "$line" '"command":""'
    assert_contains "$line" '"error":"API Error: invalid x-api-key"'
    assert_contains "$line" '"status":"401"'

    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- chronological append ---------------------------------------------------
test_appends_in_order() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"

    _zsh_ai_log_request "first"  '{"command":"echo 1"}' 0 1
    _zsh_ai_log_request "second" '{"command":"echo 2"}' 0 1
    _zsh_ai_log_request "third"  '{"command":"echo 3"}' 0 1

    local f="$(_log_file_today)"
    assert_equals "$(wc -l < "$f" | tr -d ' ')" "3"
    assert_contains "$(sed -n '1p' "$f")" '"query":"first"'
    assert_contains "$(sed -n '3p' "$f")" '"query":"third"'

    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- newlines/quotes in query are escaped (one line per record) -------------
test_escapes_special_chars() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"

    _zsh_ai_log_request $'a "quote" and\nnewline' '{"command":"echo hi"}' 0 1

    local f="$(_log_file_today)"
    # Still exactly one physical line despite the embedded newline
    assert_equals "$(wc -l < "$f" | tr -d ' ')" "1"
    assert_contains "$(cat "$f")" '\"quote\"'

    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- concurrent writes do not corrupt the file ------------------------------
test_concurrent_writes() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"

    local t i
    for t in 1 2 3 4 5; do
        (
            for i in 1 2 3 4 5 6 7 8 9 10; do
                _zsh_ai_log_request "t${t}-i${i}" '{"command":"echo x"}' 0 1
            done
        ) &
    done
    wait

    local f="$(_log_file_today)"
    # 5 writers * 10 lines = 50, no empty/torn lines
    assert_equals "$(wc -l < "$f" | tr -d ' ')" "50"
    assert_equals "$(grep -c '^$' "$f")" "0"
    assert_equals "$(grep -c '^{.*}$' "$f")" "50"

    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- _zsh_ai_finalize_content -----------------------------------------------
test_finalize_collapses_by_default() {
    setup_test_env
    local out=$(ZSH_AI_RAW_CONTENT="" _zsh_ai_finalize_content $'a\nb\nc')
    assert_equals "$out" "abc"
    teardown_test_env
}

test_finalize_keeps_newlines_in_raw_mode() {
    setup_test_env
    local out=$(ZSH_AI_RAW_CONTENT=1 _zsh_ai_finalize_content $'a\nb\nc')
    # 3 lines preserved
    assert_equals "$(printf '%s' "$out" | wc -l | tr -d ' ')" "2"
    assert_contains "$out" $'a\nb'
    teardown_test_env
}

# --- _zsh_ai_current_model --------------------------------------------------
test_current_model_per_provider() {
    setup_test_env
    export ZSH_AI_PROVIDER="qwen"; export ZSH_AI_QWEN_MODEL="qwen-flash"
    assert_equals "$(_zsh_ai_current_model)" "qwen-flash"
    export ZSH_AI_PROVIDER="anthropic"; export ZSH_AI_ANTHROPIC_MODEL="claude-haiku-4-5"
    assert_equals "$(_zsh_ai_current_model)" "claude-haiku-4-5"
    unset ZSH_AI_PROVIDER ZSH_AI_QWEN_MODEL ZSH_AI_ANTHROPIC_MODEL
    teardown_test_env
}

# --- N2: restrictive permissions --------------------------------------------
test_log_files_have_restrictive_perms() {
    setup_test_env
    local PARENT=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$PARENT/logs"   # created by logging
    export ZSH_AI_PROVIDER="openai"

    _zsh_ai_log_request "secret thing" '{"command":"echo hi"}' 0 1

    local f="$(_log_file_today)"
    assert_equals "$(stat -c %a "$ZSH_AI_LOG_DIR")" "700"
    assert_equals "$(stat -c %a "$f")" "600"

    cleanup_test_dir "$PARENT"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- N1: doc sanitizer keeps \n/\t, strips ESC ------------------------------
test_sanitize_doc_strips_escapes_keeps_newlines() {
    setup_test_env
    local raw=$(printf 'a\x1b[31mb\tc\nd')
    local out=$(_zsh_ai_sanitize_doc "$raw")
    assert_not_contains "$out" $'\x1b'
    assert_contains "$out" $'b\tc'      # tab kept
    assert_equals "$(printf '%s' "$out" | wc -l | tr -d ' ')" "1"  # newline kept
    teardown_test_env
}

# --- N4: token budget guard against JSON injection --------------------------
test_max_tokens_guard_rejects_non_integer() {
    setup_test_env
    export ZSH_AI_PROVIDER="openai"
    _zsh_ai_query_openai() { echo "TOK=$ZSH_AI_MAX_TOKENS"; }

    ZSH_AI_MAX_TOKENS='9, "temperature":9'
    assert_equals "$(_zsh_ai_query x)" "TOK=2048"
    ZSH_AI_MAX_TOKENS="4096"
    assert_equals "$(_zsh_ai_query x)" "TOK=4096"

    unfunction _zsh_ai_query_openai 2>/dev/null
    unset ZSH_AI_PROVIDER ZSH_AI_MAX_TOKENS
    teardown_test_env
}

# Run tests
run_test "Log dir is 700 and file is 600" test_log_files_have_restrictive_perms
run_test "sanitize_doc strips ESC, keeps newline/tab" test_sanitize_doc_strips_escapes_keeps_newlines
run_test "max_tokens guard rejects non-integer" test_max_tokens_guard_rejects_non_integer
run_test "Logging disabled when ZSH_AI_LOG_DIR unset" test_log_disabled_when_dir_unset
run_test "Logs a successful request line" test_logs_success_line
run_test "Logs a failed request line" test_logs_failure_line
run_test "Appends records in chronological order" test_appends_in_order
run_test "Escapes quotes/newlines into one line" test_escapes_special_chars
run_test "Concurrent writes do not corrupt the file" test_concurrent_writes
run_test "finalize_content collapses newlines by default" test_finalize_collapses_by_default
run_test "finalize_content keeps newlines in raw mode" test_finalize_keeps_newlines_in_raw_mode
run_test "current_model returns provider model" test_current_model_per_provider

finish_tests
