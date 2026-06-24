#!/usr/bin/env zsh

# Safety layer for zsh-ai:
#   - command blacklist (catastrophic commands)
#   - risk classification (blocked / high / medium / safe)
#   - CJK detection helper used by the widget for Chinese auto-routing
#
# Risk levels are returned by _zsh_ai_risk_level and consumed by lib/widget.zsh
# to (a) refuse blacklisted commands and (b) color the generated command by
# risk via region_highlight.

# --- CJK detection ----------------------------------------------------------
# Return 0 if the string contains a CJK (Han) character. Used to route Chinese
# input to the AI without requiring the "# " trigger.
_zsh_ai_contains_cjk() {
    setopt local_options multibyte
    [[ "$1" == *[$'㐀'-$'鿿']* ]] && return 0
    [[ "$1" == *[$'豈'-$'﫿']* ]] && return 0
    return 1
}

# --- Built-in pattern sets (POSIX ERE) --------------------------------------
# These are matched with `[[ $cmd =~ $pattern ]]`. rm/fork-bomb handling lives
# in code below for clarity; everything else is pattern-driven and extensible.

typeset -ga _ZSH_AI_BLACKLIST_DEFAULT=(
    '(^|[;&|[:space:]])mkfs(\.[[:alnum:]]+)?([[:space:]]|$)'
    '(^|[;&|[:space:]])dd[[:space:]].*of=/dev/(sd|nvme|disk|hd|vd|mmcblk|loop)'
    '>[[:space:]]*/dev/(sd|nvme|disk|hd|vd|mmcblk)[a-z0-9]'
    '(^|[;&|[:space:]])(fdisk|parted|wipefs|sgdisk|mkswap)[[:space:]].*/dev/'
    '(chmod|chown)[[:space:]]+-[[:alnum:]]*[rR][[:alnum:]]*[[:space:]].*[[:space:]]/([[:space:]]|$)'
)

typeset -ga _ZSH_AI_HIGH_RISK_DEFAULT=(
    '(^|[;&|[:space:]])sudo([[:space:]]|$)'
    '(^|[;&|[:space:]])dd([[:space:]]|$)'
    '(curl|wget)[[:space:]].*\|[[:space:]]*(sudo[[:space:]]+)?(sh|bash|zsh)([[:space:]]|$)'
    '(^|[;&|[:space:]])(shutdown|reboot|halt|poweroff)([[:space:]]|$)'
    '(^|[;&|[:space:]])(killall|pkill)([[:space:]]|$)'
    '(^|[;&|[:space:]])kill[[:space:]]+(-[[:alnum:]]+[[:space:]]+)*-1([[:space:]]|$)'
    '(chmod|chown)[[:space:]]+-[[:alnum:]]*[rR]'
    'git[[:space:]]+push[[:space:]].*(--force|[[:space:]]-f)([[:space:]]|$)'
    '(^|[;&|[:space:]])(iptables|nft)[[:space:]].*(-F|flush)'
    '(^|[;&|[:space:]])(userdel|groupdel|deluser)([[:space:]]|$)'
    '(^|[;&|[:space:]])(fdisk|parted|wipefs|sgdisk|mkswap)([[:space:]]|$)'
)

typeset -ga _ZSH_AI_MEDIUM_RISK_DEFAULT=(
    '(^|[;&|[:space:]])rm([[:space:]]|$)'
    '(^|[;&|[:space:]])mv([[:space:]]|$)'
    '(^|[;&|[:space:]])kill([[:space:]]|$)'
    '(^|[;&|[:space:]])(chmod|chown)([[:space:]]|$)'
    '(^|[;&|[:space:]])truncate([[:space:]]|$)'
    'git[[:space:]]+(reset[[:space:]]+--hard|clean[[:space:]]+-[[:alnum:]]*[fdx]|checkout[[:space:]]+--)'
    '(^|[;&|[:space:]])(apt|apt-get|yum|dnf|pacman|brew|npm|pip|pip3|gem|cargo|go)[[:space:]]+(install|remove|uninstall|purge|erase)'
)

# Test a command against every pattern in the given list. Returns 0 on match.
_zsh_ai_match_any() {
    local cmd="$1"; shift
    local pat
    for pat in "$@"; do
        [[ -z "$pat" ]] && continue
        [[ "$cmd" =~ $pat ]] && return 0
    done
    return 1
}

# Classify a command. Echoes one of: blocked | high | medium | safe
_zsh_ai_risk_level() {
    emulate -L zsh
    local cmd="$1"
    local nospace="${cmd// /}"

    # --- analyze rm flags once (shared by blocked + high) ---
    local rm_is_cmd=0 rm_recursive=0 rm_force=0
    # leading class includes "/" so absolute paths like /bin/rm are still caught
    if [[ "$cmd" =~ '(^|[;&|[:space:]/])rm([[:space:]]|$)' ]]; then
        rm_is_cmd=1
        if [[ "$cmd" =~ '(^|[[:space:]])-[[:alnum:]]*[rR]' ]] || [[ "$cmd" == *--recursive* ]]; then
            rm_recursive=1
        fi
        if [[ "$cmd" =~ '(^|[[:space:]])-[[:alnum:]]*[fF]' ]] || [[ "$cmd" == *--force* ]]; then
            rm_force=1
        fi
    fi

    # ---------------- BLOCKED (catastrophic) ----------------
    # user-defined blacklist takes precedence
    _zsh_ai_match_any "$cmd" "${ZSH_AI_BLACKLIST_PATTERNS[@]}" && { echo blocked; return; }
    # fork bomb (space-insensitive)
    [[ "$nospace" == *':(){'*'};:'* ]] && { echo blocked; return; }
    # rm -rf targeting a root-ish path
    if (( rm_is_cmd && rm_recursive )) && \
       [[ "$cmd" =~ '[[:space:]](/|/\*|~|~/|\$HOME|\$\{HOME\})([[:space:]]|$)' ]]; then
        echo blocked; return
    fi
    _zsh_ai_match_any "$cmd" "${_ZSH_AI_BLACKLIST_DEFAULT[@]}" && { echo blocked; return; }

    # ---------------- HIGH ----------------
    (( rm_is_cmd )) && (( rm_recursive || rm_force )) && { echo high; return; }
    _zsh_ai_match_any "$cmd" "${ZSH_AI_HIGH_RISK_PATTERNS[@]}" "${_ZSH_AI_HIGH_RISK_DEFAULT[@]}" && { echo high; return; }

    # ---------------- MEDIUM ----------------
    _zsh_ai_match_any "$cmd" "${ZSH_AI_MEDIUM_RISK_PATTERNS[@]}" "${_ZSH_AI_MEDIUM_RISK_DEFAULT[@]}" && { echo medium; return; }

    echo safe
}

# Map a risk level to a region_highlight style spec.
_zsh_ai_risk_color() {
    case "$1" in
        blocked) echo "${ZSH_AI_COLOR_BLOCKED}" ;;
        high)    echo "${ZSH_AI_COLOR_HIGH}" ;;
        medium)  echo "${ZSH_AI_COLOR_MEDIUM}" ;;
        *)       echo "${ZSH_AI_COLOR_SAFE}" ;;
    esac
}

# Map a risk level to a short human-readable label (empty for "safe").
_zsh_ai_risk_label() {
    case "$1" in
        blocked) echo "⛔ 黑名单命令" ;;
        high)    echo "⚠️  高危命令,执行前请确认" ;;
        medium)  echo "● 中等风险" ;;
        *)       echo "" ;;
    esac
}
