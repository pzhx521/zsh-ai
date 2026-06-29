# Agent Notes

This repo is a small zsh plugin that turns natural-language prompts into shell commands.

## Public Docs

- `README.md`: product pitch, quick install, usage
- `INSTALL.md`: install methods, providers, config
- `TROUBLESHOOTING.md`: setup and runtime issues
- `CONTRIBUTING.md`: contributor workflow

## Code Shape

- `zsh-ai.plugin.zsh`: loads modules
- `lib/config.zsh`: defaults and provider validation
- `lib/context.zsh`: directory, project, git, and OS context
- `lib/widget.zsh`: `# ...` comment flow
- `lib/utils.zsh`: prompt construction, provider routing, `zsh-ai`
- `lib/logging.zsh`: JSONL request logging (locked appends), gated by `ZSH_AI_LOG_DIR`
- `lib/digest.zsh`: `zsh-ai-digest` daily knowledge-base generator
- `lib/agents.zsh`: agent JSON loading + `@`+Tab completion
- `lib/chat.zsh`: `zsh-ai-chat` multi-turn agent REPL, sessions, compression,
  markdown rendering of replies via `glow` (gated by `ZSH_AI_CHAT_MARKDOWN`)
- `lib/providers/`: provider modules
- `examples/agents/`: sample agent JSON files

## Invariants

- zsh implementation, with `curl` and `perl` required
- `jq` stays optional
- commands land in the prompt before execution
- test both `# ...` and `zsh-ai "..."`
- provider changes need tests and docs
- agent chat (`lib/chat.zsh`) does NOT modify providers: `_zsh_ai_chat_complete`
  builds per-provider payloads itself and reuses the shared curl/parse helpers
- chat helpers that set globals (`_zsh_ai_chat_complete`, `_zsh_ai_chat_compress`)
  must never be called via `$(...)` — a subshell would lose those globals

## Tests

```bash
./run-tests.zsh
./run-tests.zsh tests/providers
zsh tests/config.test.zsh
```

CI runs ShellCheck, but the workflow currently does not fail on ShellCheck output.

## Provider Work

Update `lib/config.zsh`, the provider module, `tests/providers/`, `README.md`, and `INSTALL.md`. Cover API errors, empty responses, and parsing with and without `jq`.
