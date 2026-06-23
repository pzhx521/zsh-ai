#!/usr/bin/env zsh

# Context detection functions for zsh-ai

# Function to detect project type
_zsh_ai_detect_project_type() {
    local project_type="unknown"
    
    if [[ -f "package.json" ]]; then
        project_type="node"
    elif [[ -f "Cargo.toml" ]]; then
        project_type="rust"
    elif [[ -f "requirements.txt" ]] || [[ -f "setup.py" ]] || [[ -f "pyproject.toml" ]]; then
        project_type="python"
    elif [[ -f "Gemfile" ]]; then
        project_type="ruby"
    elif [[ -f "go.mod" ]]; then
        project_type="go"
    elif [[ -f "composer.json" ]]; then
        project_type="php"
    elif [[ -f "pom.xml" ]] || [[ -f "build.gradle" ]]; then
        project_type="java"
    elif [[ -f "docker-compose.yml" ]] || [[ -f "Dockerfile" ]]; then
        project_type="docker"
    fi
    
    echo "$project_type"
}

# Function to get git context
_zsh_ai_get_git_context() {
    local git_info=""
    
    if git rev-parse --is-inside-work-tree &>/dev/null; then
        local branch=$(git branch --show-current 2>/dev/null)
        local git_status="clean"
        
        if [[ -n $(git status --porcelain 2>/dev/null) ]]; then
            git_status="dirty"
        fi
        
        git_info="Git: branch=$branch, status=$git_status"
    fi
    
    echo "$git_info"
}

# Function to get directory context
_zsh_ai_get_directory_context() {
    local dir_context="Current directory: $(pwd)"
    local file_count=$(ls -1 2>/dev/null | wc -l | tr -d ' ')
    
    if [[ $file_count -le 20 ]]; then
        local files=$(ls -1 2>/dev/null | head -10 | tr '\n' ',' | sed 's/,$//' | sed 's/,/, /g')
        if [[ -n "$files" ]]; then
            dir_context="$dir_context\nFiles: $files"
            if [[ $file_count -gt 10 ]]; then
                dir_context="$dir_context ... and $((file_count - 10)) more"
            fi
        fi
    else
        dir_context="$dir_context\nFiles: $file_count files in directory"
    fi
    
    echo "$dir_context"
}

# Function to build context
#
# Privacy note: only the OS type is sent to the model. The directory path, file
# listing, project type, and git branch/status are intentionally NOT included,
# since they can leak internal paths, secret file names, and project codenames.
# The helper functions above are kept for reuse but are no longer wired in here.
_zsh_ai_build_context() {
    echo "OS: $(uname -s)"
}