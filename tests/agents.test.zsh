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

# --- Tab trigger scoping ----------------------------------------------------
# (buffer, lbuffer) -> should agent completion fire?
test_tab_should_complete_scoping() {
    setup_test_env
    # YES: typing the leading @id token
    _zsh_ai_agent_tab_should_complete "@eng"        "@eng"     || TEST_FAILED=1
    _zsh_ai_agent_tab_should_complete "@english"    "@eng"     || TEST_FAILED=1  # cursor mid-token
    _zsh_ai_agent_tab_should_complete "@"           "@"        || TEST_FAILED=1
    # NO: not a leading @ (normal commands / paths / refs)
    _zsh_ai_agent_tab_should_complete "git status"  "git st"   && TEST_FAILED=1
    _zsh_ai_agent_tab_should_complete "scp user@ho" "scp user@ho" && TEST_FAILED=1  # @ mid-word
    _zsh_ai_agent_tab_should_complete "npm i @ang"  "npm i @ang"  && TEST_FAILED=1  # @ in a later word
    _zsh_ai_agent_tab_should_complete "ls ~/@x"     "ls ~/@x"  && TEST_FAILED=1
    # NO: leading @ but cursor already past the first word (typing a message)
    _zsh_ai_agent_tab_should_complete "@eng hello"  "@eng hel" && TEST_FAILED=1
    teardown_test_env
}

# Run all tests
run_test "Tab agent-completion only on leading @ token" test_tab_should_complete_scoping
run_test "Agent id validation blocks traversal/slash/dots" test_id_valid
run_test "Agent ids are listed" test_agent_ids_listed
run_test "Agent ids empty when dir missing" test_agent_ids_empty_when_no_dir
run_test "Agent name and multi-line prompt read" test_agent_name_and_prompt
run_test "Agent name falls back to id" test_agent_name_falls_back_to_id
run_test "Agent existence check" test_agent_exists
run_test "Agents dir default path" test_agents_dir_default

finish_tests
