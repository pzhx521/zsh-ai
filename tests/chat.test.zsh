#!/usr/bin/env zsh

# Load test helper
source "${0:A:h}/test_helper.zsh"

# Load modules needed for chat
source "$PLUGIN_DIR/lib/config.zsh"
source "$PLUGIN_DIR/lib/safety.zsh"
source "$PLUGIN_DIR/lib/context.zsh"
source "$PLUGIN_DIR/lib/utils.zsh"
source "$PLUGIN_DIR/lib/logging.zsh"
source "$PLUGIN_DIR/lib/agents.zsh"
source "$PLUGIN_DIR/lib/chat.zsh"

# --- message payload building ----------------------------------------------
test_msgs_json_with_and_without_system() {
    setup_test_env
    local effective_system="SYS"
    local -a turn_roles turn_contents
    turn_roles=(user assistant); turn_contents=("hi" "yo")
    local with_sys="$(_zsh_ai_chat_msgs_json 1)"
    local no_sys="$(_zsh_ai_chat_msgs_json 0)"
    assert_contains "$with_sys" '{"role":"system","content":"SYS"}'
    assert_contains "$with_sys" '{"role":"user","content":"hi"}'
    assert_not_contains "$no_sys" '"system"'
    assert_contains "$no_sys" '{"role":"assistant","content":"yo"}'
    teardown_test_env
}

test_msgs_json_escapes_quotes() {
    setup_test_env
    local effective_system="S"
    local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=('say "hi"')
    local out="$(_zsh_ai_chat_msgs_json 1)"
    assert_contains "$out" '\"hi\"'
    teardown_test_env
}

test_contents_json_maps_assistant_to_model() {
    setup_test_env
    local -a turn_roles turn_contents
    turn_roles=(user assistant); turn_contents=("q" "a")
    local out="$(_zsh_ai_chat_contents_json)"
    assert_contains "$out" '{"role":"user","parts":[{"text":"q"}]}'
    assert_contains "$out" '{"role":"model","parts":[{"text":"a"}]}'
    teardown_test_env
}

# --- small helpers ----------------------------------------------------------
test_human_size() {
    setup_test_env
    assert_equals "$(_zsh_ai_human_size 512)" "512 B"
    assert_equals "$(_zsh_ai_human_size 1536)" "1.5 KB"
    assert_equals "$(_zsh_ai_human_size 1572864)" "1.5 MB"
    teardown_test_env
}

test_sid_format() {
    setup_test_env
    local sid="$(_zsh_ai_chat_sid)"
    [[ "$sid" == <-> && ${#sid} -eq 9 ]] || { echo "bad sid: $sid"; TEST_FAILED=1; }
    teardown_test_env
}

test_session_time_format() {
    setup_test_env
    assert_equals "$(_zsh_ai_chat_session_time /x/session-142233871.jsonl)" "14:22:33"
    teardown_test_env
}

test_truncate_width() {
    setup_test_env
    # 6 CJK chars = 12 cols; truncate to 10 -> 5 chars + ellipsis
    local out="$(_zsh_ai_chat_truncate "一二三四五六七八" 10)"
    assert_contains "$out" "…"
    teardown_test_env
}

# --- session round-trip -----------------------------------------------------
test_session_append_load_roundtrip() {
    setup_test_env
    export ZSH_AI_LOG_DIR=$(mktemp -d)
    local sf="$ZSH_AI_LOG_DIR/s.jsonl"
    local multi=$'line1\nline2\twith tab\nline3'
    _zsh_ai_chat_append_line "$sf" system "PROMPT"
    _zsh_ai_chat_append_line "$sf" user "q1"
    _zsh_ai_chat_append_line "$sf" assistant "$multi"
    _zsh_ai_chat_append_line "$sf" user "q2 例子"

    # file perms 600
    assert_equals "$(stat -c '%a' "$sf")" "600"

    local -a turn_roles turn_contents
    local current_summary; integer rounds
    _zsh_ai_chat_load_session "$sf"
    # system line ignored; 2 user + 1 assistant = 3 turns, 2 rounds
    assert_equals "${#turn_roles[@]}" "3"
    assert_equals "$rounds" "2"
    # multi-line + tab content survives exactly
    assert_equals "$turn_contents[2]" "$multi"
    cleanup_test_dir "$ZSH_AI_LOG_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

test_last_query() {
    setup_test_env
    export ZSH_AI_LOG_DIR=$(mktemp -d)
    local sf="$ZSH_AI_LOG_DIR/s.jsonl"
    _zsh_ai_chat_append_line "$sf" user "first"
    _zsh_ai_chat_append_line "$sf" assistant "reply"
    _zsh_ai_chat_append_line "$sf" user "最后一问"
    assert_equals "$(_zsh_ai_chat_last_query "$sf")" "最后一问"
    cleanup_test_dir "$ZSH_AI_LOG_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

# --- session listing / dates ------------------------------------------------
test_agent_dates_and_files_desc() {
    setup_test_env
    export ZSH_AI_LOG_DIR=$(mktemp -d)
    local base="$ZSH_AI_LOG_DIR/sessions/eng"
    mkdir -p "$base/2026-06-20" "$base/2026-06-25" "$base/2026-06-26"
    # an empty date dir should be ignored
    mkdir -p "$base/2026-06-21"
    touch "$base/2026-06-20/session-100000000.jsonl"
    touch "$base/2026-06-25/session-090000000.jsonl"
    touch "$base/2026-06-26/session-080000000.jsonl"
    touch "$base/2026-06-26/session-093000000.jsonl"

    local dates="$(_zsh_ai_chat_agent_dates eng)"
    # desc order, empty 2026-06-21 excluded
    local expected=$'2026-06-26\n2026-06-25\n2026-06-20'
    assert_equals "$dates" "$expected"

    # two files on 2026-06-26, newest first
    local files="$(_zsh_ai_chat_session_files eng 2026-06-26)"
    local first="${files%%$'\n'*}"
    assert_contains "$first" "session-093000000.jsonl"
    cleanup_test_dir "$ZSH_AI_LOG_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

# --- compression ------------------------------------------------------------
test_compress_rewrites_and_snapshots() {
    setup_test_env
    export ZSH_AI_LOG_DIR=$(mktemp -d)
    local sdir="$ZSH_AI_LOG_DIR/sessions/eng/2026-06-26"
    mkdir -p "$sdir"
    local session_file="$sdir/session-100000000.jsonl"
    local agent_id="eng" agent_prompt="PROMPT" current_summary=""
    local -a turn_roles turn_contents
    turn_roles=(user assistant user assistant)
    turn_contents=("q1" "a1" "q2" "a2")
    integer rounds=4
    _zsh_ai_chat_append_line "$session_file" system "PROMPT"
    local i
    for i in 1 2 3 4; do _zsh_ai_chat_append_line "$session_file" "${turn_roles[i]}" "${turn_contents[i]}"; done

    # mock the model summary call
    _zsh_ai_chat_oneshot() { ZSH_AI_CHAT_REPLY="SUMMARY-TEXT"; return 0; }

    # NOTE: do NOT wrap in $() - compress sets globals that a subshell would lose
    # (the same reason zsh-ai-chat never command-substitutes it). Capture the
    # human report (stderr) to a file so it runs in the current shell.
    local reportfile=$(mktemp)
    _zsh_ai_chat_compress 2>"$reportfile"
    local rc=$?
    local report="$(cat "$reportfile")"; rm -f "$reportfile"
    assert_equals "$rc" "0"
    assert_equals "$ZSH_AI_CHAT_NEW_SUMMARY" "SUMMARY-TEXT"
    assert_contains "$report" "已压缩"
    assert_contains "$report" "4 轮"

    # main file is now system + summary only
    local body="$(cat "$session_file")"
    assert_contains "$body" '"role":"system"'
    assert_contains "$body" '"role":"summary","content":"SUMMARY-TEXT"'
    assert_not_contains "$body" '"content":"q1"'

    # a raw-*.jsonl snapshot of the pre-compression file exists with all turns
    local raw=$(print -l "$sdir"/raw-*.jsonl(N) | head -1)
    assert_not_empty "$raw"
    assert_contains "$(cat "$raw")" '"content":"q1"'

    # reload: summary restored, zero live rounds
    _zsh_ai_chat_load_session "$session_file"
    assert_equals "$current_summary" "SUMMARY-TEXT"
    assert_equals "${#turn_roles[@]}" "0"

    cleanup_test_dir "$ZSH_AI_LOG_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

test_compress_noop_when_no_turns() {
    setup_test_env
    local agent_id="eng" agent_prompt="P" current_summary="" session_file="/tmp/none"
    local -a turn_roles turn_contents
    integer rounds=0
    _zsh_ai_chat_compress 2>/dev/null
    assert_equals "$?" "1"
    teardown_test_env
}

# --- chat_complete dispatch (openai, mocked curl) ---------------------------
test_chat_complete_openai_parses_content() {
    setup_test_env
    export ZSH_AI_PROVIDER="openai"
    export OPENAI_API_KEY="sk-test"
    export ZSH_AI_OPENAI_MODEL="gpt-5.4-mini"
    mock_curl_response '{"choices":[{"message":{"role":"assistant","content":"Hello there 你好"}}]}'
    local effective_system="SYS"
    local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("hi")
    _zsh_ai_chat_complete
    assert_equals "$?" "0"
    assert_equals "$ZSH_AI_CHAT_REPLY" "Hello there 你好"
    unset ZSH_AI_PROVIDER OPENAI_API_KEY ZSH_AI_OPENAI_MODEL
    teardown_test_env
}

test_chat_unlimited_omits_token_cap() {
    setup_test_env
    export ZSH_AI_PROVIDER="openai"
    export OPENAI_API_KEY="sk-test"
    export ZSH_AI_OPENAI_MODEL="gpt-4o"   # non-reasoning -> would carry temperature
    unset ZSH_AI_CHAT_MAX_TOKENS          # default = unlimited
    mock_curl_response '{"choices":[{"message":{"content":"ok"}}]}'
    local effective_system="S"; local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("hi")
    _zsh_ai_chat_complete
    # No token cap key should appear in the sent payload.
    assert_not_contains "$ZSH_AI_LAST_REQUEST" "max_tokens"
    assert_not_contains "$ZSH_AI_LAST_REQUEST" "max_completion_tokens"
    unset ZSH_AI_PROVIDER OPENAI_API_KEY ZSH_AI_OPENAI_MODEL
    teardown_test_env
}

test_chat_cap_when_set() {
    setup_test_env
    export ZSH_AI_PROVIDER="openai"
    export OPENAI_API_KEY="sk-test"
    export ZSH_AI_OPENAI_MODEL="gpt-5.4-mini"
    export ZSH_AI_CHAT_MAX_TOKENS="500"
    mock_curl_response '{"choices":[{"message":{"content":"ok"}}]}'
    local effective_system="S"; local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("hi")
    _zsh_ai_chat_complete
    assert_contains "$ZSH_AI_LAST_REQUEST" '"max_completion_tokens": 500'
    unset ZSH_AI_PROVIDER OPENAI_API_KEY ZSH_AI_OPENAI_MODEL ZSH_AI_CHAT_MAX_TOKENS
    teardown_test_env
}

test_chat_non_integer_cap_treated_as_unlimited() {
    setup_test_env
    export ZSH_AI_PROVIDER="openai"
    export OPENAI_API_KEY="sk-test"
    export ZSH_AI_OPENAI_MODEL="gpt-5.4-mini"
    export ZSH_AI_CHAT_MAX_TOKENS='9, "temperature":9'   # injection attempt
    mock_curl_response '{"choices":[{"message":{"content":"ok"}}]}'
    local effective_system="S"; local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("hi")
    _zsh_ai_chat_complete
    # Malformed value is dropped, never interpolated into the JSON body.
    assert_not_contains "$ZSH_AI_LAST_REQUEST" 'temperature":9'
    assert_not_contains "$ZSH_AI_LAST_REQUEST" "max_completion_tokens"
    unset ZSH_AI_PROVIDER OPENAI_API_KEY ZSH_AI_OPENAI_MODEL ZSH_AI_CHAT_MAX_TOKENS
    teardown_test_env
}

test_chat_anthropic_always_caps() {
    setup_test_env
    export ZSH_AI_PROVIDER="anthropic"
    export ANTHROPIC_API_KEY="sk-test"
    export ZSH_AI_ANTHROPIC_MODEL="claude-haiku-4-5"
    unset ZSH_AI_CHAT_MAX_TOKENS          # unlimited everywhere except anthropic
    mock_curl_response '{"content":[{"text":"ok"}]}'
    local effective_system="S"; local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("hi")
    _zsh_ai_chat_complete
    # Anthropic requires max_tokens, so it falls back to 8192.
    assert_contains "$ZSH_AI_LAST_REQUEST" '"max_tokens": 8192'
    unset ZSH_AI_PROVIDER ANTHROPIC_API_KEY ZSH_AI_ANTHROPIC_MODEL
    teardown_test_env
}

test_chat_complete_surfaces_api_error() {
    setup_test_env
    export ZSH_AI_PROVIDER="openai"
    export OPENAI_API_KEY="sk-test"
    export ZSH_AI_OPENAI_MODEL="gpt-5.4-mini"
    mock_curl_response '{"error":{"message":"invalid api key"}}'
    local effective_system="SYS"
    local -a turn_roles turn_contents
    turn_roles=(user); turn_contents=("hi")
    _zsh_ai_chat_complete
    assert_equals "$?" "1"
    assert_contains "$ZSH_AI_CHAT_ERR" "invalid api key"
    unset ZSH_AI_PROVIDER OPENAI_API_KEY ZSH_AI_OPENAI_MODEL
    teardown_test_env
}

# --- guard rails ------------------------------------------------------------
test_chat_requires_log_dir() {
    setup_test_env
    export ZSH_AI_LOG_DIR=""
    local out="$(zsh-ai-chat english-teacher 2>&1)"
    assert_contains "$out" "ZSH_AI_LOG_DIR"
    unset ZSH_AI_LOG_DIR
    teardown_test_env
}

test_chat_errors_on_unknown_agent() {
    setup_test_env
    export ZSH_AI_LOG_DIR=$(mktemp -d)
    export ZSH_AI_AGENTS_DIR=$(mktemp -d)
    local out="$(zsh-ai-chat no-such-agent 2>&1 </dev/null)"
    assert_contains "$out" "找不到 agent"
    cleanup_test_dir "$ZSH_AI_LOG_DIR"; cleanup_test_dir "$ZSH_AI_AGENTS_DIR"
    unset ZSH_AI_LOG_DIR ZSH_AI_AGENTS_DIR
    teardown_test_env
}

# Run all tests
run_test "Build messages JSON with/without system" test_msgs_json_with_and_without_system
run_test "Messages JSON escapes quotes" test_msgs_json_escapes_quotes
run_test "Gemini contents maps assistant to model" test_contents_json_maps_assistant_to_model
run_test "Human-readable byte size" test_human_size
run_test "Session id is 9 digits" test_sid_format
run_test "Session time formatting" test_session_time_format
run_test "Truncate by display width" test_truncate_width
run_test "Session append/load round-trip (multiline+tab)" test_session_append_load_roundtrip
run_test "Last user query parsed" test_last_query
run_test "Agent dates and files listed desc, empty skipped" test_agent_dates_and_files_desc
run_test "Compression rewrites main + snapshots raw" test_compress_rewrites_and_snapshots
run_test "Compression is a no-op with no turns" test_compress_noop_when_no_turns
run_test "chat_complete parses OpenAI content" test_chat_complete_openai_parses_content
run_test "Unlimited (default) omits token cap" test_chat_unlimited_omits_token_cap
run_test "Integer ZSH_AI_CHAT_MAX_TOKENS caps reply" test_chat_cap_when_set
run_test "Non-integer cap is dropped (no injection)" test_chat_non_integer_cap_treated_as_unlimited
run_test "Anthropic always sends max_tokens (8192 fallback)" test_chat_anthropic_always_caps
run_test "chat_complete surfaces API error" test_chat_complete_surfaces_api_error
run_test "Chat requires ZSH_AI_LOG_DIR" test_chat_requires_log_dir
run_test "Chat errors on unknown agent" test_chat_errors_on_unknown_agent

finish_tests
