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

# --- @ + Tab completion -----------------------------------------------------
#
# Completion is delegated: a Tab widget checks whether the word under the cursor
# starts with "@". If so it completes agent ids; otherwise it falls back to the
# user's original Tab binding, so normal completion is untouched.

# Completion widget body (runs in completion context, so compadd is available).
_zsh_ai_complete_agents_inner() {
    local -a raw ids names
    raw=( ${(f)"$(_zsh_ai_agent_ids)"} )
    local id
    for id in "${raw[@]}"; do
        [[ -n "$id" ]] || continue
        ids+=("@$id")
        names+=("$(_zsh_ai_agent_name "$id")")
    done
    (( ${#ids} )) || return 1
    # Show the human name as the description next to each @id candidate.
    compadd -d names -- "${ids[@]}"
}

# The Tab widget: agent completion for @words, original Tab otherwise.
_zsh_ai_tab_widget() {
    local word="${LBUFFER##*[[:space:]]}"
    if [[ "$word" == @* ]]; then
        zle _zsh_ai_complete_agents && return
    fi
    zle "${_zsh_ai_orig_tab:-expand-or-complete}"
}

# Register the Tab widget once ZLE is ready. Captures whatever Tab was bound to
# so the fallback preserves the user's existing completion behavior.
_zsh_ai_init_agent_completion() {
    _zsh_ai_agent_tab_enabled || return

    _zsh_ai_do_agent_completion_init() {
        # Remember the current Tab binding to fall back to (default if unset).
        local binding current
        binding="$(bindkey '^I')"        # e.g.  "^I" expand-or-complete
        current="${binding##* }"
        if [[ -n "$current" && "$current" != _zsh_ai_tab_widget && "$current" != undefined-key ]]; then
            typeset -g _zsh_ai_orig_tab="$current"
        else
            typeset -g _zsh_ai_orig_tab="expand-or-complete"
        fi
        zmodload zsh/complist 2>/dev/null
        zle -C _zsh_ai_complete_agents menu-complete _zsh_ai_complete_agents_inner
        zle -N _zsh_ai_tab_widget
        bindkey '^I' _zsh_ai_tab_widget
        add-zsh-hook -d precmd _zsh_ai_do_agent_completion_init
    }
    autoload -Uz add-zsh-hook
    add-zsh-hook precmd _zsh_ai_do_agent_completion_init
}
