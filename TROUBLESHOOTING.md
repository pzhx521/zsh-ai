# Troubleshooting

Start with the direct command so errors are easy to see:

```bash
zsh-ai "show current date"
```

## API Key Missing

```bash
zsh-ai: Warning: ANTHROPIC_API_KEY not set. Plugin will not function.
```

Set the key for your provider:

```bash
export ANTHROPIC_API_KEY="your-key"
```

For permanent setup, put the key above the `zsh-ai` load line in a private `~/.zshrc`.

Or switch to Ollama:

```bash
export ZSH_AI_PROVIDER="ollama"
```

## Ollama Is Not Running

```bash
Error: Ollama is not running at http://localhost:11434
```

```bash
ollama serve
ollama pull llama3.2
```

## Nothing Happens With `#`

Reload your shell config:

```bash
source ~/.zshrc
```

Then test the explicit command:

```bash
zsh-ai "list files"
```

If that works, restart your terminal so the zle widget binding reloads.

## Pasting Code Breaks `#` Comments

If you paste code blocks that start with `# comment` lines, the inline hook can
intercept the first line and fire an unwanted query. Either change the trigger to
something you won't paste, or disable the hook and use `zsh-ai "..."` instead:

```bash
# Use a different trigger
export ZSH_AI_TRIGGER=",,"

# Or turn the inline hook off entirely
export ZSH_AI_COMMENT_HOOK="false"
```

See [INSTALL.md](INSTALL.md#inline-trigger) for details.

## JSON Parse Errors

Install `jq`:

```bash
brew install jq
```

Ubuntu or Debian:

```bash
sudo apt-get install jq
```

## Empty Or Truncated Reply

If a request fails with an empty response and the diagnostics show
`finish_reason: length`, the model hit the output token cap. Reasoning models
(DeepSeek, o-series, …) spend part of the budget on hidden chain-of-thought and
may run out before writing the command. Raise the cap:

```bash
export ZSH_AI_MAX_TOKENS="4096"
```

## Requests Hang Or Time Out

Requests are bounded by `ZSH_AI_CONNECT_TIMEOUT` (default 10s) and
`ZSH_AI_TIMEOUT` (default 60s); a timeout surfaces as a connection error with
diagnostics. On a slow link or large model, raise them:

```bash
export ZSH_AI_TIMEOUT="120"
```

The digest uses `ZSH_AI_DIGEST_TIMEOUT` (default 180s) since it streams a long
document.

## Agent Chat Issues

`@` + Tab shows nothing: check that agent files exist and are valid ids.

```bash
ls "${ZSH_AI_AGENTS_DIR:-$HOME/.config/zsh-ai/agents}"   # expect <id>.json files
```

Agent ids may only contain letters, digits, `_` and `-`. `@` completion works by
prepending a completer to your `completer` zstyle (so a command-position word
starting with `@` offers agent ids); it does **not** rebind the Tab key, so it
works alongside menu completion, fzf-tab, etc., and your normal completion is
untouched. It needs the completion system initialized (`compinit`), which
oh-my-zsh and most setups do already. To verify it registered:

```bash
zstyle -L ':completion:*' completer   # should list _zsh_ai_completer first
```

If `compinit` warns `insecure directories` on macOS/Homebrew, fix the dir
permissions (`compaudit | xargs chmod g-w`) or initialize with `compinit -i`.

If it still doesn't trigger, disable it and start the chat explicitly:

```bash
export ZSH_AI_AGENT_TAB="false"
zsh-ai-chat english-teacher
```

`zsh-ai-chat: 需要先设置 ZSH_AI_LOG_DIR`: agent chat saves sessions to disk, so
set `ZSH_AI_LOG_DIR`:

```bash
export ZSH_AI_LOG_DIR="$HOME/.zsh-ai/logs"
```

To leave a chat, type `quit` (or `exit` / `:q`). The session is saved to
`$ZSH_AI_LOG_DIR/sessions/<agent-id>/<date>/session-<time>.jsonl`.

Replies show raw markdown (literal `##`, `**`, code fences): install
[`glow`](https://github.com/charmbracelet/glow) so `zsh-ai-chat` can render them.

```bash
brew install glow
```

`zsh-ai-chat` auto-detects `glow` on your `PATH` at startup and prints a hint
when it is missing. Set `ZSH_AI_CHAT_MARKDOWN="off"` to force plain text and
silence that hint.

## Inspecting Requests

When logging is enabled (`ZSH_AI_LOG_DIR`), every request is recorded as JSON in
`$ZSH_AI_LOG_DIR/YYYY-MM-DD.jsonl` (no API keys). For a full request/response
trace, enable debug logging:

```bash
export ZSH_AI_DEBUG="true"
export ZSH_AI_DEBUG_LOG="$HOME/.zsh-ai-debug.log"   # default
```

## Still Stuck

Check the active provider and model:

```bash
zsh-ai
```

Then open an issue with your OS, zsh version, provider, install method, and exact error:

https://github.com/matheusml/zsh-ai/issues
