#!/usr/bin/env zsh

# Agent (role / persona) definitions for zsh-ai chat.
#
# An "agent" is a JSON file in $ZSH_AI_AGENTS_DIR (default ~/.config/zsh-ai/agents)
# whose name is "<id>.json" and whose body is:
#     { "id": "english-teacher", "name": "英语教师", "prompt": "You are ..." }
#
# The agent's "prompt" becomes the system prompt of a chat session (see
# lib/chat.zsh). Typing "@" then Tab on the command line completes agent ids.

# Echo the directory that holds agent JSON files.
_zsh_ai_agents_dir() {
    echo "${ZSH_AI_AGENTS_DIR:-$HOME/.config/zsh-ai/agents}"
}

# Validate an agent id: only [A-Za-z0-9_-], non-empty. This is used in file
# paths, so it must never contain "/", "..", spaces or shell metacharacters.
_zsh_ai_agent_id_valid() {
    [[ -n "$1" && "$1" =~ '^[A-Za-z0-9_-]+$' ]]
}

# Path to an agent's JSON file (does not check existence).
_zsh_ai_agent_file() {
    echo "$(_zsh_ai_agents_dir)/$1.json"
}

# Return 0 if the agent exists (valid id + readable JSON file).
_zsh_ai_agent_exists() {
    local id="$1"
    _zsh_ai_agent_id_valid "$id" || return 1
    [[ -r "$(_zsh_ai_agent_file "$id")" ]]
}

# List all agent ids (basenames of *.json with a valid id), one per line.
_zsh_ai_agent_ids() {
    emulate -L zsh
    setopt local_options null_glob
    local dir="$(_zsh_ai_agents_dir)"
    [[ -d "$dir" ]] || return 0
    local f id
    for f in "$dir"/*.json; do
        id="${${f:t}%.json}"
        _zsh_ai_agent_id_valid "$id" && echo "$id"
    done
}

# Read a top-level string field (id/name/prompt) from an agent's JSON file.
# Prefers jq, falls back to perl (a required dependency). Control characters
# are stripped so a crafted agent file can't smuggle ANSI escapes.
_zsh_ai_agent_field() {
    emulate -L zsh
    local id="$1" field="$2"
    _zsh_ai_agent_exists "$id" || return 1
    local file="$(_zsh_ai_agent_file "$id")"
    local result

    if command -v jq >/dev/null 2>&1; then
        result="$(jq -er --arg f "$field" '.[$f] // empty' "$file" 2>/dev/null)"
        if [[ $? -eq 0 ]]; then
            _zsh_ai_sanitize_doc "$result"
            return 0
        fi
    fi

    result="$(FIELD="$field" perl -0777 -ne '
        my $f = quotemeta($ENV{FIELD});
        if (/"$f"\s*:\s*"((?:[^"\\]|\\.)*)"/s) {
            my $v = $1;
            $v =~ s/\\n/\n/g; $v =~ s/\\t/\t/g; $v =~ s/\\r//g;
            $v =~ s/\\"/"/g; $v =~ s/\\\\/\\/g;
            print $v;
        }
    ' "$file" 2>/dev/null)"
    _zsh_ai_sanitize_doc "$result"
}

# Display name for an agent (falls back to the id when "name" is absent).
_zsh_ai_agent_name() {
    local id="$1" name
    name="$(_zsh_ai_agent_field "$id" name)"
    [[ -n "$name" ]] && echo "$name" || echo "$id"
}

# The agent's system prompt.
_zsh_ai_agent_prompt() {
    _zsh_ai_agent_field "$1" prompt
}

# --- @ completion -----------------------------------------------------------
#
# Agents are completed by hooking the COMPLETION SYSTEM, not the Tab key: when
# the FIRST word of the line starts with "@", completing it offers agent ids.
# This never rebinds Tab — your existing Tab/completion (menu, fzf-tab,
# zsh-autocomplete, …) is used as-is and is completely untouched.
#
# It is implemented as a custom completer prepended to the `completer` zstyle.
# A pattern completion (`compdef -p _zsh_ai_agents '@*'`) does NOT work here: that
# governs how the ARGUMENTS of a command named "@…" are completed, not how the
# command word itself is completed — so it never fires for a leading "@". The
# completer runs first, handles only a command-position "@…" word, and otherwise
# returns non-zero so the rest of your completer chain runs unchanged.

# Build the agent-id candidates (runs in completion context, so compadd/_describe
# work). Returns non-zero when there are no agents, so completion falls through.
_zsh_ai_agents() {
    local -a raw ids disp
    raw=( ${(f)"$(_zsh_ai_agent_ids)"} )
    local id
    for id in "${raw[@]}"; do
        [[ -n "$id" ]] || continue
        ids+=("@$id")
        disp+=("@$id:$(_zsh_ai_agent_name "$id")")
    done
    (( ${#ids} )) || return 1
    if (( ${+functions[_describe]} )); then
        _describe -t zsh-ai-agents 'zsh-ai agent' disp ids
    else
        compadd -- "${ids[@]}"
    fi
}

# Custom completer: only acts on a command-position word beginning with "@";
# otherwise returns 1 so the next completer in the chain takes over.
_zsh_ai_completer() {
    [[ $CURRENT -eq 1 && "$PREFIX" == @* ]] || return 1
    _zsh_ai_agents
}

# Register by prepending _zsh_ai_completer to the `completer` zstyle, preserving
# whatever the user already has. Idempotent. The completion system must be up
# (compinit run) for the `completer` style to be consulted, so this returns 1
# until then and is retried from a precmd hook (see below).
_zsh_ai_register_agent_completion() {
    (( ${+functions[compdef]} )) || return 1
    local -a cur
    zstyle -a ':completion:*' completer cur || cur=(_complete _ignored)
    if [[ ${cur[(I)_zsh_ai_completer]} -eq 0 ]]; then
        zstyle ':completion:*' completer _zsh_ai_completer "${cur[@]}"
    fi
    return 0
}

# Install the completion. Tries immediately (compinit may already have run, e.g.
# under oh-my-zsh); otherwise RETRIES on every prompt until the completion system
# is up, then stops. The earlier version removed its hook after a single attempt,
# so if compinit had not run yet the registration was silently lost — this keeps
# retrying instead.
_zsh_ai_init_agent_completion() {
    _zsh_ai_agent_tab_enabled || return
    _zsh_ai_register_agent_completion && return

    _zsh_ai_do_agent_completion_init() {
        if _zsh_ai_register_agent_completion; then
            add-zsh-hook -d precmd _zsh_ai_do_agent_completion_init
        fi
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _zsh_ai_do_agent_completion_init
}
