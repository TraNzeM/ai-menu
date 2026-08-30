# ai-menu plugins collection

Collection of Noctalia v5 plugins.

## Plugins

### [AI Menu](ai-menu/) — `tranzem/ai-menu`

AI-command overlay over selected text via Hermes API: select text → Ctrl+Alt+Space → pick a command → streaming response → Copy / Replace / Insert / Chat / Write.

Features: streaming (`httpStream`), tool-progress statuses, persistent Hermes session, `clear_session` toggle, en/ru localization, 21 commands (`commands.json`), Docker-ready (`env_file`, `chat_command`).

See [ai-menu/README.md](ai-menu/README.md) for full docs.

## Install (Noctalia v5)

```bash
noctalia msg plugins source add ai-menu git https://github.com/TraNzeM/ai-menu
noctalia msg plugins enable tranzem/ai-menu
```

Or local development:

```bash
noctalia msg plugins source add local-dev path /path/to/this/repo
noctalia msg plugins enable tranzem/ai-menu
```
