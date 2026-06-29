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

`zsh-ai` stays on the command line. For privacy it sends only your OS type as
context (no path, file listing, project type, or git state), and the model uses
it to pick platform-correct commands — the same request maps to BSD flags on
macOS and GNU flags on Linux.

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

The system prompt is tuned to return a **directly runnable** command, not a
template. In particular it instructs the model to:

- avoid placeholders like `<file>` or `path/to/dir` — use a concrete default or
  let the shell discover the value (e.g. `$(git branch --show-current)`);
- pick platform-correct commands/flags from your OS (`Darwin` = macOS/BSD,
  `Linux` = GNU coreutils — e.g. `sed -i ''` vs `sed -i`);
- chain multi-step work on a single line with `&&` / `|` (never a newline);
- prefer non-destructive forms and avoid `--force`/`-f` unless you asked for it;
- never invent non-existent subcommands or flags — when a request can't be made
  reliable, it returns the closest best-effort command and states the assumption.

For install commands (`apt`, `brew`, `npm`, `pip`, `cargo`, …) the explanation
also tells you **what the software/SDK is for**, not just that it installs it.

Layer your own preferences on top without losing these rules via
`ZSH_AI_PROMPT_EXTEND` (see [Configuration](#configuration)).

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

### Troubleshooting failed requests

When a request fails, zsh-ai prints a diagnostic block to help you debug:

```text
API Error: invalid x-api-key
──────── zsh-ai 诊断信息(排查用)────────
HTTP 状态码 : 401
请求地址    : https://api.anthropic.com/v1/messages
请求体      : { "model": "claude-haiku-4-5", ... }
原始响应    : {"error":{"message":"invalid x-api-key"}}
(注:请求头含密钥,未打印)
```

The endpoint is redacted (API keys passed in the URL are masked) and request
headers are never printed, so your API key is not leaked. Set `ZSH_AI_DEBUG=true`
to also append every request/response to a log file for deeper investigation:

```bash
export ZSH_AI_DEBUG="true"
export ZSH_AI_DEBUG_LOG="$HOME/.zsh-ai-debug.log"   # default
```

## Request logging & daily digest

Set `ZSH_AI_LOG_DIR` and every request is appended as one JSON line to a daily
log; leave it unset to disable logging entirely.

```bash
export ZSH_AI_LOG_DIR="$HOME/.zsh-ai/logs"
```

Each line in `$ZSH_AI_LOG_DIR/YYYY-MM-DD.jsonl` records the timestamp, provider,
model, OS, your query, and the parsed result (command / explanation / parameters
/ risk / HTTP status / error). **API keys and the system prompt are never
logged** — only your query and the result. Records append in chronological
order, and concurrent writes from multiple terminals are serialized with a lock
(`flock` on Linux, a portable `mkdir` lock fallback elsewhere, e.g. macOS). The
log directory is created `700` and the files `600`, since a query can contain
things you typed.

```json
{"ts":"2026-06-25T14:03:21+0800","provider":"openai","model":"deepseek-v4-flash","os":"Linux (GNU coreutils)","query":"找出占用8080端口的进程并杀掉","ok":true,"status":"200","command":"lsof -ti:8080 | xargs kill -9","explanation":"…","parameters":"…","risk":"high","error":""}
```

### Daily knowledge base

`zsh-ai-digest` reads a day's log, aggregates the commands (deduped and ranked by
how often you used them), asks the model to write a markdown knowledge base, and
saves it under `$ZSH_AI_LOG_DIR/memory/YYYY-MM-DD.md` (kept separate from the raw
`.jsonl` logs):

```bash
zsh-ai-digest            # summarize today
zsh-ai-digest 2026-06-25 # summarize a specific day
```

The document ranks the most-used commands first, explains each command's purpose
and key parameters (including what installed software/SDKs are for), and adds
real, version-tagged extended command demos. It is kept concise (≤ 400 lines).
It reuses your `ZSH_AI_PROVIDER`/model but lifts the per-command token cap to
`ZSH_AI_DIGEST_MAX_TOKENS` (default `16384`) since the document is long.

If a day produced no successfully-generated commands (even if there were failed
requests), `zsh-ai-digest` skips silently — no model call, no file written.

The generated document is stripped of terminal control/escape sequences and
opens with a disclaimer: its commands (and extended demos) are AI-generated and
unverified — confirm before running. Anything you actually run still goes through
the live safety/blacklist layer.

Run it nightly at 18:00 via cron (the digest covers that day's 00:00–18:00).
cron has no interactive shell, so use the bundled launcher
`scripts/digest-cron.zsh`: it sources a repo-external env file for your
provider/key, then loads the plugin and runs the digest — **no secrets in the
repo**.

Put your secrets in `~/.config/zsh-ai/env` (chmod 600), outside the repo:

```bash
export ZSH_AI_LOG_DIR="$HOME/.zsh-ai/logs"
export ZSH_AI_PROVIDER="openai"
export OPENAI_API_KEY="sk-…"
```

Then add the cron line (point it at your clone):

```cron
0 18 * * * /usr/bin/zsh /path/to/zsh-ai/scripts/digest-cron.zsh >> "$HOME/.zsh-ai/logs/digest.cron.log" 2>&1
```

> Override the env-file path with `ZSH_AI_ENV_FILE`. Test it once by hand first:
> `zsh scripts/digest-cron.zsh`.

## Agent chat

Beyond one-shot command generation, zsh-ai has a multi-turn **agent chat**. An
agent is a role/persona defined by a small JSON file; chatting with one is a
framed REPL that remembers the conversation and saves it to disk.

### Define an agent

Drop a `<id>.json` file in `$ZSH_AI_AGENTS_DIR` (default
`~/.config/zsh-ai/agents`). See [`examples/agents/`](examples/agents) for
ready-made ones — `english-teacher` (英语教师), `sql-helper` (SQL 助手), and
`shell-engineer` (终端命令工程师).

```json
{ "id": "english-teacher", "name": "英语教师", "prompt": "You are a patient English teacher. Correct mistakes and explain briefly." }
```

```bash
mkdir -p ~/.config/zsh-ai/agents
cp examples/agents/*.json ~/.config/zsh-ai/agents/   # copy all bundled examples
```

### Start a chat

Type `@` and press **Tab** to complete an agent id, then press **Enter** to open
the chat (optionally type a first message after the id):

```bash
@english-teacher                       # open a chat
@english-teacher how do I use "since"? # open a chat with a first message
```

The agent's `prompt` becomes the system prompt. The whole conversation is framed
until you type `quit`:

```
╭─ 💬 @英语教师 ──────────────────────────────────────────────────────╮
│ 输入消息开始对话;输入 quit 退出。
│ 你 › How do I use the present perfect tense?
│ 英语教师 › Use "have/has" + past participle:
│ - I have finished my homework.
╰─────────────────────────────────────────────────────────────────────╯
```

You can also start it explicitly: `zsh-ai-chat english-teacher`.

### Sessions

Agent chat needs `ZSH_AI_LOG_DIR` set (sessions are saved to disk). Each session
is one JSON-line-per-message file:

```
$ZSH_AI_LOG_DIR/sessions/<agent-id>/<YYYY-MM-DD>/session-<HHMMSSmmm>.jsonl
```

When you `@`-open an agent that already has sessions, you get a picker: `[0]` is
a new session (the default — just press Enter), and existing sessions are listed
under date headers showing each one's last question. It starts with **today's**
sessions; `[m]` reveals the next five days that have sessions, and so on.

### History compression

Every `ZSH_AI_CHAT_MAX_ROUNDS` rounds (default 10) you're asked whether to
compress the history. If you agree, the model summarizes the conversation into a
single line, the live turns are replaced by that summary (the agent prompt is
**never** compressed), and you get a size report:

```
✓ 已压缩  10 轮 / 22 行 / 8.4 KB  →  2 行 / 1.1 KB
  备份: raw-142233871-152011455.jsonl
```

The full pre-compression file is snapshotted alongside the session as
`raw-<session-id>-<compress-time>.jsonl`, so nothing is ever lost.

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

Cap the tokens the model may **generate** (default `2048`). Reasoning models
(DeepSeek, o-series, …) spend part of this budget on hidden chain-of-thought, so
a value that's too low can leave nothing for the actual command and the reply
comes back empty (`finish_reason: length`). Raise it for heavy reasoning models,
lower it to save cost on plain models:

```bash
export ZSH_AI_MAX_TOKENS="2048"
```

> This limits output only — it does not affect how much context is sent.

Tune [agent chat](#agent-chat):

```bash
export ZSH_AI_AGENTS_DIR="$HOME/.config/zsh-ai/agents"  # where agent JSON lives
export ZSH_AI_CHAT_MAX_ROUNDS="10"      # offer to compress history every N rounds
export ZSH_AI_CHAT_MAX_TOKENS=""        # output cap; empty = unlimited (default)
export ZSH_AI_CHAT_TIMEOUT="120"        # request timeout (s) for a chat turn
export ZSH_AI_AGENT_TAB="false"         # disable "@" agent completion
export ZSH_AI_CHAT_MARKDOWN="auto"      # render replies with glow if installed; "off" = plain
```

> `@` completion prepends a completer to your `completer` zstyle, so a
> command-position word starting with `@` offers agent ids. It uses your existing
> Tab (menu, fzf-tab, …), never rebinds the Tab key, and leaves normal completion
> untouched. It needs the completion system (`compinit`) initialized.

> Replies are markdown. With [`glow`](https://github.com/charmbracelet/glow) on
> your `PATH` they render with headings, lists, and code blocks; without it you
> get plain text and a one-line install hint at the start of a chat. `brew install
> glow`, or set `ZSH_AI_CHAT_MARKDOWN="off"` to keep plain text and hide the hint.

> Chat replies (and compression summaries) are uncapped by default —
> `ZSH_AI_CHAT_MAX_TOKENS` is empty, so the model uses its own maximum. Set a
> bare integer to cap output. (Anthropic's API requires `max_tokens`, so when
> uncapped it falls back to `8192` for that provider only.)

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
