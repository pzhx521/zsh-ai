#!/usr/bin/env zsh

# Load test helper
source "${0:A:h}/test_helper.zsh"

# Load required modules
source "$PLUGIN_DIR/lib/config.zsh"
source "$PLUGIN_DIR/lib/safety.zsh"

# --- CJK detection ----------------------------------------------------------

test_cjk_detects_chinese() {
    _zsh_ai_contains_cjk "列出当前目录文件" && return 0
    TEST_FAILED=1
}

test_cjk_detects_mixed_chinese() {
    _zsh_ai_contains_cjk "git 提交所有改动" && return 0
    TEST_FAILED=1
}

test_cjk_ignores_ascii() {
    if _zsh_ai_contains_cjk "list all files"; then
        TEST_FAILED=1
    fi
    return 0
}

test_cjk_ignores_plain_command() {
    if _zsh_ai_contains_cjk "ls -la | grep foo"; then
        TEST_FAILED=1
    fi
    return 0
}

# --- risk classification: blocked -------------------------------------------

test_rm_rf_root_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level 'rm -rf /')" "blocked"
}

test_rm_rf_root_glob_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level 'rm -rf /*')" "blocked"
}

test_rm_rf_home_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level 'sudo rm -rf ~')" "blocked"
}

test_fork_bomb_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level ':(){ :|:& };:')" "blocked"
}

test_mkfs_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level 'mkfs.ext4 /dev/sdb1')" "blocked"
}

test_dd_to_disk_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level 'dd if=/dev/zero of=/dev/sda bs=1M')" "blocked"
}

test_chmod_r_root_is_blocked() {
    assert_equals "$(_zsh_ai_risk_level 'chmod -R 777 /')" "blocked"
}

# --- risk classification: high ----------------------------------------------

test_rm_rf_subdir_is_high() {
    assert_equals "$(_zsh_ai_risk_level 'rm -rf node_modules')" "high"
}

test_sudo_is_high() {
    assert_equals "$(_zsh_ai_risk_level 'sudo apt update')" "high"
}

test_curl_pipe_sh_is_high() {
    assert_equals "$(_zsh_ai_risk_level 'curl http://x.sh | sh')" "high"
}

test_git_push_force_is_high() {
    assert_equals "$(_zsh_ai_risk_level 'git push --force origin main')" "high"
}

test_chmod_r_nonroot_is_high() {
    assert_equals "$(_zsh_ai_risk_level 'chmod -R 777 /etc')" "high"
}

# --- risk classification: medium --------------------------------------------

test_rm_file_is_medium() {
    assert_equals "$(_zsh_ai_risk_level 'rm file.txt')" "medium"
}

test_mv_is_medium() {
    assert_equals "$(_zsh_ai_risk_level 'mv a b')" "medium"
}

test_git_reset_hard_is_medium() {
    assert_equals "$(_zsh_ai_risk_level 'git reset --hard HEAD')" "medium"
}

# --- risk classification: safe ----------------------------------------------

test_ls_is_safe() {
    assert_equals "$(_zsh_ai_risk_level 'ls -la')" "safe"
}

test_echo_is_safe() {
    assert_equals "$(_zsh_ai_risk_level 'echo hello world')" "safe"
}

test_rm_substring_not_flagged() {
    # "confirm" / "alarm" contain "rm" but are not the rm command
    assert_equals "$(_zsh_ai_risk_level 'echo confirm')" "safe"
}

# --- user-defined patterns --------------------------------------------------

test_user_blacklist_pattern() {
    typeset -ga ZSH_AI_BLACKLIST_PATTERNS=('(^|[[:space:]])terraform[[:space:]]+destroy')
    assert_equals "$(_zsh_ai_risk_level 'terraform destroy -auto-approve')" "blocked"
    unset ZSH_AI_BLACKLIST_PATTERNS
}

test_user_high_risk_pattern() {
    typeset -ga ZSH_AI_HIGH_RISK_PATTERNS=('(^|[[:space:]])kubectl[[:space:]]+delete')
    assert_equals "$(_zsh_ai_risk_level 'kubectl delete pod foo')" "high"
    unset ZSH_AI_HIGH_RISK_PATTERNS
}

# --- color / label helpers --------------------------------------------------

test_color_high_uses_config() {
    local ZSH_AI_COLOR_HIGH="fg=red,bold"
    assert_equals "$(_zsh_ai_risk_color high)" "fg=red,bold"
}

test_color_safe_uses_config() {
    local ZSH_AI_COLOR_SAFE="fg=green"
    assert_equals "$(_zsh_ai_risk_color safe)" "fg=green"
}

test_label_safe_is_empty() {
    assert_equals "$(_zsh_ai_risk_label safe)" ""
}

test_label_blocked_not_empty() {
    assert_not_empty "$(_zsh_ai_risk_label blocked)"
}

# --- toggles ----------------------------------------------------------------

test_safety_toggle_off() {
    local ZSH_AI_SAFETY="false"
    if _zsh_ai_safety_enabled; then TEST_FAILED=1; fi
    return 0
}

test_safety_toggle_on_by_default() {
    local ZSH_AI_SAFETY="true"
    _zsh_ai_safety_enabled && return 0
    TEST_FAILED=1
}

test_chinese_detect_toggle_off() {
    local ZSH_AI_CHINESE_DETECT="off"
    if _zsh_ai_chinese_detect_enabled; then TEST_FAILED=1; fi
    return 0
}

# Run tests
echo "Running safety tests..."
run_test "CJK: detects Chinese" test_cjk_detects_chinese
run_test "CJK: detects mixed Chinese" test_cjk_detects_mixed_chinese
run_test "CJK: ignores ASCII" test_cjk_ignores_ascii
run_test "CJK: ignores plain command" test_cjk_ignores_plain_command
run_test "Risk: rm -rf / is blocked" test_rm_rf_root_is_blocked
run_test "Risk: rm -rf /* is blocked" test_rm_rf_root_glob_is_blocked
run_test "Risk: rm -rf ~ is blocked" test_rm_rf_home_is_blocked
run_test "Risk: fork bomb is blocked" test_fork_bomb_is_blocked
run_test "Risk: mkfs is blocked" test_mkfs_is_blocked
run_test "Risk: dd to disk is blocked" test_dd_to_disk_is_blocked
run_test "Risk: chmod -R 777 / is blocked" test_chmod_r_root_is_blocked
run_test "Risk: rm -rf subdir is high" test_rm_rf_subdir_is_high
run_test "Risk: sudo is high" test_sudo_is_high
run_test "Risk: curl | sh is high" test_curl_pipe_sh_is_high
run_test "Risk: git push --force is high" test_git_push_force_is_high
run_test "Risk: chmod -R non-root is high" test_chmod_r_nonroot_is_high
run_test "Risk: rm file is medium" test_rm_file_is_medium
run_test "Risk: mv is medium" test_mv_is_medium
run_test "Risk: git reset --hard is medium" test_git_reset_hard_is_medium
run_test "Risk: ls is safe" test_ls_is_safe
run_test "Risk: echo is safe" test_echo_is_safe
run_test "Risk: rm substring not flagged" test_rm_substring_not_flagged
run_test "User blacklist pattern works" test_user_blacklist_pattern
run_test "User high-risk pattern works" test_user_high_risk_pattern
run_test "Color: high uses config" test_color_high_uses_config
run_test "Color: safe uses config" test_color_safe_uses_config
run_test "Label: safe is empty" test_label_safe_is_empty
run_test "Label: blocked not empty" test_label_blocked_not_empty
run_test "Toggle: safety off" test_safety_toggle_off
run_test "Toggle: safety on by default" test_safety_toggle_on_by_default
run_test "Toggle: chinese detect off" test_chinese_detect_toggle_off
finish_tests
