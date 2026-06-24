# zsh-ai

> Ask your shell for the command you meant to write.

<img src="https://img.shields.io/github/v/release/matheusml/zsh-ai?label=version&color=yellow" alt="Version"> <img src="https://img.shields.io/badge/runtime-zsh-blue" alt="zsh runtime"> <img src="https://img.shields.io/badge/jq-optional-lightgrey" alt="jq optional"> <img src="https://img.shields.io/github/license/matheusml/zsh-ai?color=lightgrey" alt="License">

The hard part of the terminal usually is not knowing what to do. It is remembering the exact flags, quoting, and pipeline shape.

`zsh-ai` turns a zsh comment into a command. Type `#`, describe the job, press Enter, and the generated command appears in your prompt.

```bash
$ # find files larger than 100mb changed this week
$ find . -type f -size +100M -mtime -7
```

It does not run the command for you. You read it first, edit it if needed, then press Enter again.

## Why This Is Different

Most command help breaks your flow: search result, forum thread, copied snippet, little edits, fingers crossed.

`zsh-ai` stays on the command line. It sends useful context with your request, including project type, nearby files, git state, and OS. That means "run tests" can become the right command for the directory you are already in.

It is also small by design: zsh plus `curl` and `perl`, no Node runtime, no Python runtime. `jq` is optional.

## Install

```bash
brew install matheusml/zsh-ai/zsh-ai
```

Add this to `~/.zshrc`, with the API key above the `source` line:

```bash
export ANTHROPIC_API_KEY="your-key-here"
source $(brew --prefix)/share/zsh-ai/zsh-ai.plugin.zsh
```

Keep API keys out of public dotfiles.

Reload your shell:

```bash
source ~/.zshrc
```

Then try:

```bash
# summarize disk usage for this folder
```

Prefer a local model on your machine?

```bash
ollama pull llama3.2
export ZSH_AI_PROVIDER="ollama"
```

Put the Ollama provider line above the `zsh-ai` source line.

Full setup lives in [INSTALL.md](INSTALL.md).

## Usage

### Comment Syntax

Type `#`, describe the job, then press Enter.

The trigger is configurable, and the inline hook can be turned off entirely if you
only want the `zsh-ai "..."` command — see [Configuration](#configuration).

<img src="https://github.com/user-attachments/assets/eff46629-855c-41eb-9de3-a53040bd2654" alt="zsh-ai comment syntax demo" width="520">

```bash
$ # show what is using port 3000
$ lsof -i :3000

$ # show commits on this branch that are not on main
$ git log main..HEAD --oneline
```

### Direct Command

<img src="https://github.com/user-attachments/assets/e58f0b99-68bf-45a5-87b9-ba7f925ddc87" alt="zsh-ai direct command demo" width="520">

```bash
$ zsh-ai "find large files modified this week"
$ find . -type f -size +50M -mtime -7
```

The command is pushed into your prompt with `print -z`, ready to edit or run.

### Output format

The model returns a single JSON object describing the command:

```json
{
  "command": "find . -name '*.log' -mtime +7 -delete",
  "explanation": "1-2 line summary of what the command does",
  "parameters": "1-2 line explanation of the key flags/arguments"
}
```

The explanation/parameters follow the language of your request (Chinese in,
Chinese out). If a model ever replies with plain text instead of JSON, the
whole reply is used as the command, so nothing breaks.

#### Box mode (default)

By default the command, explanation, parameters, and a confirmation warning are
shown inside a framed box, and **the input line is left empty** — the command is
never pasted into your prompt, so you can't run it by accident. Copy or retype
it once you've confirmed it:

```text
╭────────────────────────────────────────────╮
│ find . -name '*.log' -mtime +7 -delete       │
├────────────────────────────────────────────┤
│ 说明  删除 7 天前的日志文件。                  │
│ 参数  -mtime +7 超过7天;-delete 删除匹配项。   │
├────────────────────────────────────────────┤
│ !! 请人工确认无误后再执行                      │
╰────────────────────────────────────────────╯
```

The command is colored by risk level, and the warning escalates for high-risk
(`!! 高危命令`) and blacklisted (`XX 命中黑名单`) commands.

#### Buffer mode

Prefer the command dropped straight into your editable prompt (the original
behavior)? Switch modes:

```bash
export ZSH_AI_OUTPUT_MODE="buffer"
```

In buffer mode the command lands in your prompt with the explanation shown
above it, blacklisted commands are refused, and the command is colored by risk.

### Chinese / natural-language auto-detection

You don't always need the `#` trigger. When a line contains Chinese (CJK)
characters, it is sent to the AI automatically:

```bash
$ 找出占用 8080 端口的进程并杀掉
$ lsof -ti:8080 | xargs kill -9
```

The model detects your OS and shell from the context, so the same request maps
to the right command on Linux or macOS. Turn detection off if you frequently run
commands that embed Chinese literals (e.g. `echo 你好`):

```bash
export ZSH_AI_CHINESE_DETECT="false"
```

### Safety: blacklist + risk coloring

Generated commands are never auto-executed — they land in your prompt for you to
confirm. On top of that, `zsh-ai` classifies every generated command:

- **blocked** — catastrophic commands (`rm -rf /`, fork bombs, `mkfs`, `dd` to a
  disk, `chmod -R 777 /`, …). By default these are *refused* and never placed in
  your prompt.
- **high** (red) — `sudo`, `rm -rf <dir>`, `curl … | sh`, `git push --force`, …
- **medium** (yellow) — `rm`, `mv`, `kill`, `git reset --hard`, package installs, …
- **safe** (green) — everything else.

The generated command is colored by risk level, and high-risk/blocked commands
print a short warning.

```bash
# Disable the whole safety layer
export ZSH_AI_SAFETY="false"

# Fill blacklisted commands anyway (colored red) instead of refusing them
export ZSH_AI_BLACKLIST_ACTION="warn"

# Customize colors (any zsh highlight spec)
export ZSH_AI_COLOR_HIGH="fg=red,bold"
export ZSH_AI_COLOR_MEDIUM="fg=yellow"
export ZSH_AI_COLOR_SAFE="fg=green"

# Add your own patterns (POSIX ERE); these extend the built-in defaults
export ZSH_AI_BLACKLIST_PATTERNS=('(^|[[:space:]])terraform[[:space:]]+destroy')
export ZSH_AI_HIGH_RISK_PATTERNS=('(^|[[:space:]])kubectl[[:space:]]+delete')
export ZSH_AI_MEDIUM_RISK_PATTERNS=()
```

> Note: if you use [zsh-syntax-highlighting](https://github.com/zsh-users/zsh-syntax-highlighting),
> it manages `region_highlight` on every redraw and will override the risk color.
> The blacklist refusal and warnings still work regardless.

## Configuration

Switch providers with `ZSH_AI_PROVIDER`:

```bash
export ZSH_AI_PROVIDER="openai"
export OPENAI_API_KEY="your-key-here"
```

Add command preferences without replacing the built-in quoting rules:

```bash
export ZSH_AI_PROMPT_EXTEND="Prefer rg over grep, fd over find, and bat over cat."
```

Change the inline trigger, or disable the comment hook altogether (handy when you
paste code blocks that start with `#` comments):

```bash
# Use ,, instead of "# " to start a query
export ZSH_AI_TRIGGER=",,"

# Disable the inline hook entirely; only `zsh-ai "..."` stays active
export ZSH_AI_COMMENT_HOOK="false"
```

## Docs

- [Installation](INSTALL.md)
- [Troubleshooting](TROUBLESHOOTING.md)
- [Contributing](CONTRIBUTING.md)
