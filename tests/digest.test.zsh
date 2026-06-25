#!/usr/bin/env zsh

# Load test helper
source "${0:A:h}/test_helper.zsh"

# Load modules needed for the digest
source "$PLUGIN_DIR/lib/config.zsh"
source "$PLUGIN_DIR/lib/safety.zsh"
source "$PLUGIN_DIR/lib/context.zsh"
source "$PLUGIN_DIR/lib/utils.zsh"
source "$PLUGIN_DIR/lib/logging.zsh"
source "$PLUGIN_DIR/lib/digest.zsh"

# Write a small fixture log for a fixed date.
_write_fixture() {
    local dir="$1" date_str="$2"
    cat > "$dir/$date_str.jsonl" <<'EOF'
{"ts":"x","provider":"openai","model":"m","os":"Linux","query":"杀端口","ok":true,"status":"200","command":"lsof -ti:8080 | xargs kill -9","explanation":"e","parameters":"p","risk":"high","error":""}
{"ts":"x","provider":"openai","model":"m","os":"Linux","query":"杀端口","ok":true,"status":"200","command":"lsof -ti:8080 | xargs kill -9","explanation":"e","parameters":"p","risk":"high","error":""}
{"ts":"x","provider":"openai","model":"m","os":"Linux","query":"找大文件","ok":true,"status":"200","command":"find . -type f -size +100M","explanation":"e","parameters":"p","risk":"safe","error":""}
{"ts":"x","provider":"openai","model":"m","os":"Linux","query":"坏请求","ok":false,"status":"401","command":"","explanation":"","parameters":"","risk":"","error":"API Error: invalid x-api-key"}
EOF
}

# --- aggregation ------------------------------------------------------------
test_aggregate_counts_and_order() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    _write_fixture "$TEST_DIR" "2026-06-25"

    local agg=$(_zsh_ai_digest_aggregate "$TEST_DIR/2026-06-25.jsonl" "2026-06-25")
    assert_contains "$agg" "DATE	2026-06-25"
    assert_contains "$agg" "requests=4"
    assert_contains "$agg" "success=3"
    assert_contains "$agg" "failed=1"
    # Most-used command (count 2) must appear before the count-1 command
    local top=$(printf '%s' "$agg" | grep -n 'lsof -ti:8080' | head -1 | cut -d: -f1)
    local low=$(printf '%s' "$agg" | grep -n 'find . -type f' | head -1 | cut -d: -f1)
    assert_greater_than "$low" "$top"
    # Failure captured
    assert_contains "$agg" "invalid x-api-key"

    cleanup_test_dir "$TEST_DIR"
    teardown_test_env
}

# --- guard rails ------------------------------------------------------------
test_digest_errors_without_log_dir() {
    setup_test_env
    export ZSH_AI_LOG_DIR=""
    local out=$(zsh-ai-digest 2>&1)
    assert_contains "$out" "ZSH_AI_LOG_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

test_digest_errors_when_file_missing() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    local out=$(zsh-ai-digest "2000-01-01" 2>&1)
    assert_contains "$out" "找不到日志文件"
    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

# --- skip when no successful commands ---------------------------------------
test_digest_skips_when_no_successful_commands() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"
    # log with only a failed request
    cat > "$TEST_DIR/2026-06-25.jsonl" <<'EOF'
{"ts":"x","provider":"openai","model":"m","os":"Linux","query":"坏请求","ok":false,"status":"401","command":"","explanation":"","parameters":"","risk":"","error":"API Error: bad key"}
EOF
    # model must NOT be called
    _zsh_ai_query() { echo "MODEL_CALLED" > "$TEST_DIR/_called"; print -r -- "x"; }

    local out rc
    out=$(zsh-ai-digest "2026-06-25" 2>&1)
    rc=$?
    assert_contains "$out" "跳过"
    assert_equals "$rc" "0"
    [[ ! -f "$TEST_DIR/memory/2026-06-25.md" ]] || { echo "md should not exist"; TEST_FAILED=1; }
    [[ ! -f "$TEST_DIR/_called" ]] || { echo "model should not be called"; TEST_FAILED=1; }

    unfunction _zsh_ai_query 2>/dev/null
    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- end-to-end with a mocked model -----------------------------------------
test_digest_writes_markdown_with_overrides() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"
    _write_fixture "$TEST_DIR" "2026-06-25"

    # Capture the overrides the digest sets, return multi-line markdown
    _zsh_ai_query() {
        echo "RAW=${ZSH_AI_RAW_CONTENT:-0} MAX=${ZSH_AI_MAX_TOKENS} TMO=${ZSH_AI_TIMEOUT} SYS=${#ZSH_AI_SYSTEM_PROMPT}" >> "$TEST_DIR/_seen"
        print -r -- "# 今日命令知识库 · 2026-06-25"
        print -r -- ""
        print -r -- "## 高频命令"
    }

    local out=$(zsh-ai-digest "2026-06-25" 2>/dev/null)
    assert_contains "$out" "已生成"

    local md="$TEST_DIR/memory/2026-06-25.md"
    assert_contains "$(cat "$md")" "今日命令知识库"
    # newlines preserved (more than one line)
    assert_greater_than "$(wc -l < "$md" | tr -d ' ')" "1"
    # overrides were in effect during the model call
    assert_contains "$(cat "$TEST_DIR/_seen")" "RAW=1"
    assert_contains "$(cat "$TEST_DIR/_seen")" "MAX=16384"
    assert_contains "$(cat "$TEST_DIR/_seen")" "TMO=180"

    unfunction _zsh_ai_query 2>/dev/null
    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- N5: invalid date is rejected -------------------------------------------
test_digest_rejects_bad_date() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    local out rc
    out=$(zsh-ai-digest "../../etc/passwd" 2>&1)
    rc=$?
    assert_contains "$out" "日期格式无效"
    assert_equals "$rc" "1"
    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

# --- N1/N3: written md is ESC-free and carries the disclaimer ---------------
test_digest_md_sanitized_with_disclaimer() {
    setup_test_env
    local TEST_DIR=$(create_test_dir)
    export ZSH_AI_LOG_DIR="$TEST_DIR"
    export ZSH_AI_PROVIDER="openai"
    _write_fixture "$TEST_DIR" "2026-06-25"
    # model returns content with an embedded ESC sequence
    _zsh_ai_query() { printf '正文\x1b[31m带ESC\n## 标题'; }

    zsh-ai-digest "2026-06-25" >/dev/null 2>&1
    local md="$TEST_DIR/memory/2026-06-25.md"
    assert_contains "$(head -1 "$md")" "本文档由 AI 自动生成"
    assert_not_contains "$(cat "$md")" $'\x1b'

    unfunction _zsh_ai_query 2>/dev/null
    cleanup_test_dir "$TEST_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_PROVIDER
    teardown_test_env
}

# --- system prompt override -------------------------------------------------
test_system_prompt_override() {
    setup_test_env
    local out=$(ZSH_AI_SYSTEM_PROMPT="CUSTOM-DIGEST-PROMPT" _zsh_ai_get_system_prompt "ctx")
    assert_equals "$out" "CUSTOM-DIGEST-PROMPT"
    # Without override, the normal command prompt is returned
    local normal=$(_zsh_ai_get_system_prompt "ctx")
    assert_contains "$normal" "zsh command generator"
    teardown_test_env
}

# Run tests
run_test "Aggregate counts totals and orders by frequency" test_aggregate_counts_and_order
run_test "Digest errors without ZSH_AI_LOG_DIR" test_digest_errors_without_log_dir
run_test "Digest errors when log file missing" test_digest_errors_when_file_missing
run_test "Digest skips when no successful commands" test_digest_skips_when_no_successful_commands
run_test "Digest writes markdown with raw/max overrides" test_digest_writes_markdown_with_overrides
run_test "Digest rejects invalid date argument" test_digest_rejects_bad_date
run_test "Digest md is ESC-free with disclaimer" test_digest_md_sanitized_with_disclaimer
run_test "System prompt override replaces base prompt" test_system_prompt_override

finish_tests
