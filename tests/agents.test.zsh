#!/usr/bin/env zsh

# Load test helper
source "${0:A:h}/test_helper.zsh"

# Load modules needed for agents
source "$PLUGIN_DIR/lib/config.zsh"
source "$PLUGIN_DIR/lib/safety.zsh"
source "$PLUGIN_DIR/lib/context.zsh"
source "$PLUGIN_DIR/lib/utils.zsh"
source "$PLUGIN_DIR/lib/agents.zsh"

# Create a temp agents dir with two agents (one without a "name").
_setup_agents() {
    local dir=$(mktemp -d)
    cat > "$dir/english-teacher.json" <<'JSON'
{ "id": "english-teacher", "name": "英语教师", "prompt": "You are a patient English teacher.\nCorrect mistakes." }
JSON
    cat > "$dir/sql-helper.json" <<'JSON'
{ "id": "sql-helper", "prompt": "You help write SQL." }
JSON
    echo "$dir"
}

# --- id validation ----------------------------------------------------------
test_id_valid() {
    setup_test_env
    _zsh_ai_agent_id_valid "english-teacher" || { TEST_FAILED=1; }
    _zsh_ai_agent_id_valid "a_b-9" || { TEST_FAILED=1; }
    # invalid: traversal, slash, dots, spaces, empty
    _zsh_ai_agent_id_valid "../etc/passwd" && TEST_FAILED=1
    _zsh_ai_agent_id_valid "a/b" && TEST_FAILED=1
    _zsh_ai_agent_id_valid "a.b" && TEST_FAILED=1
    _zsh_ai_agent_id_valid "a b" && TEST_FAILED=1
    _zsh_ai_agent_id_valid "" && TEST_FAILED=1
    teardown_test_env
}

# --- listing ----------------------------------------------------------------
test_agent_ids_listed() {
    setup_test_env
    export ZSH_AI_AGENTS_DIR=$(_setup_agents)
    local ids="$(_zsh_ai_agent_ids)"
    assert_contains "$ids" "english-teacher"
    assert_contains "$ids" "sql-helper"
    cleanup_test_dir "$ZSH_AI_AGENTS_DIR"
    unset ZSH_AI_AGENTS_DIR
    teardown_test_env
}

test_agent_ids_empty_when_no_dir() {
    setup_test_env
    export ZSH_AI_AGENTS_DIR="/nonexistent/zsh-ai-agents-$$"
    local ids="$(_zsh_ai_agent_ids)"
    assert_equals "$ids" ""
    unset ZSH_AI_AGENTS_DIR
    teardown_test_env
}

# --- field reading ----------------------------------------------------------
test_agent_name_and_prompt() {
    setup_test_env
    export ZSH_AI_AGENTS_DIR=$(_setup_agents)
    assert_equals "$(_zsh_ai_agent_name english-teacher)" "英语教师"
    local prompt="$(_zsh_ai_agent_prompt english-teacher)"
    assert_contains "$prompt" "patient English teacher"
    # multi-line prompt preserved
    assert_contains "$prompt" "Correct mistakes."
    cleanup_test_dir "$ZSH_AI_AGENTS_DIR"
    unset ZSH_AI_AGENTS_DIR
    teardown_test_env
}

test_agent_name_falls_back_to_id() {
    setup_test_env
    export ZSH_AI_AGENTS_DIR=$(_setup_agents)
    # sql-helper.json has no "name" -> name() returns the id
    assert_equals "$(_zsh_ai_agent_name sql-helper)" "sql-helper"
    cleanup_test_dir "$ZSH_AI_AGENTS_DIR"
    unset ZSH_AI_AGENTS_DIR
    teardown_test_env
}

test_agent_exists() {
    setup_test_env
    export ZSH_AI_AGENTS_DIR=$(_setup_agents)
    _zsh_ai_agent_exists english-teacher || TEST_FAILED=1
    _zsh_ai_agent_exists nope && TEST_FAILED=1
    # traversal id never resolves to a file
    _zsh_ai_agent_exists "../../etc/passwd" && TEST_FAILED=1
    cleanup_test_dir "$ZSH_AI_AGENTS_DIR"
    unset ZSH_AI_AGENTS_DIR
    teardown_test_env
}

# --- agents dir default -----------------------------------------------------
test_agents_dir_default() {
    setup_test_env
    unset ZSH_AI_AGENTS_DIR
    assert_equals "$(_zsh_ai_agents_dir)" "$HOME/.config/zsh-ai/agents"
    teardown_test_env
}

# --- @ completion registration ----------------------------------------------
# The completer is prepended to the `completer` zstyle, NOT registered with
# `compdef -p` (which would only govern arguments of an "@…"-named command).
test_completer_noop_without_completion_system() {
    setup_test_env
    unset 'functions[compdef]' 2>/dev/null
    # With no completion system (no compdef), registration must be a no-op.
    _zsh_ai_register_agent_completion && TEST_FAILED=1
    teardown_test_env
}

test_completer_prepended_preserving_chain() {
    setup_test_env
    functions[compdef]='true'   # pretend the completion system is up
    zstyle ':completion:*' completer _expand _complete _ignored
    _zsh_ai_register_agent_completion || TEST_FAILED=1
    local -a cur
    zstyle -a ':completion:*' completer cur
    # ours runs first, the user's chain is preserved after it
    assert_equals "${cur[1]}" "_zsh_ai_completer"
    assert_contains "${cur[*]}" "_expand"
    assert_contains "${cur[*]}" "_complete"
    # idempotent: a second call must not add a duplicate
    _zsh_ai_register_agent_completion
    zstyle -a ':completion:*' completer cur
    assert_equals "${(M)#cur:#_zsh_ai_completer}" "1"
    zstyle -d ':completion:*' completer
    unset 'functions[compdef]'
    teardown_test_env
}

test_completer_falls_through_for_non_at() {
    setup_test_env
    # Not command position -> return 1 (let the chain continue), no agent lookup.
    local CURRENT=2 PREFIX="@foo"
    _zsh_ai_completer && TEST_FAILED=1
    # Command position but not "@" -> return 1.
    CURRENT=1 PREFIX="ls"
    _zsh_ai_completer && TEST_FAILED=1
    teardown_test_env
}

# Run all tests
run_test "Agent id validation blocks traversal/slash/dots" test_id_valid
run_test "Agent ids are listed" test_agent_ids_listed
run_test "Agent ids empty when dir missing" test_agent_ids_empty_when_no_dir
run_test "Agent name and multi-line prompt read" test_agent_name_and_prompt
run_test "Agent name falls back to id" test_agent_name_falls_back_to_id
run_test "Agent existence check" test_agent_exists
run_test "Agents dir default path" test_agents_dir_default
run_test "Completer is a no-op before completion system is up" test_completer_noop_without_completion_system
run_test "Completer is prepended, preserving the chain, idempotently" test_completer_prepended_preserving_chain
run_test "Completer falls through for non-command-position / non-@" test_completer_falls_through_for_non_at

finish_tests
