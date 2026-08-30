# AI Menu — Noctalia v5 plugin

AI-command overlay over selected text via the Hermes API: select text → Ctrl+Alt+Space → pick a command → streaming response → Copy / Insert / Replace / Chat.

Works with any Hermes-compatible API (OpenAI format).

## Features

- **Streaming responses**: tokens appear as they are generated (first token in ~2–4s instead of the full 16–25s wait)
- **Tool-calls**: when the model runs a tool (calculator, terminal — e.g. "what is 8*9"), the panel shows the tool status ("🐍 python3 -c …"); the final answer arrives in the stream
- **Persistent session**: all requests share one `ai-menu` session (context persists between requests)
- **Clear session**: "clear session before each request" toggle (DELETE /api/sessions/ai-menu — no session proliferation)
- **Localization**: en/ru panel UI (via the `language` setting)
- **21 commands** from `~/.config/ai-menu/commands.json`, "Ask me anything" = free-form question
- **Keyboard + mouse**: Up/Down to pick, Enter to run, Esc to close, wheel to scroll
- **Actions**: Copy / Insert / Replace / Chat (text buttons) + Retry (refresh icon)

## Install

1. Add the plugin source and enable it:
   ```bash
   noctalia msg plugins source add ai-menu git https://github.com/TraNZeM/ai-menu
   noctalia msg plugins enable tranzem/ai-menu
   ```
   > **Note:** after adding a git source, Noctalia clones it in the background. If the plugin does not appear immediately, restart Noctalia (or wait for the auto-update tick).
2. Hotkey (example for Umbriel, `~/.config/umbriel/config.toml`):
   ```toml
   "Ctrl+Alt+Space" = "spawn:noctalia msg panel-toggle tranzem/ai-menu:panel"
   ```

Copy the example config to get started:

```bash
cp ai-menu/commands.example.json ~/.config/ai-menu/commands.json
```

## Settings (Noctalia GUI: Plugins → AI Menu)

| Setting | Default | Description |
|---|---|---|
| `base_url` | `http://127.0.0.1:8642` | Hermes API address |
| `model` | `deepseek-v4-flash` | Model |
| `env_file` | `~/.hermes/.env` | File with `API_SERVER_KEY` |
| `commands_file` | `~/.config/ai-menu/commands.json` | Commands file |
| `clear_session` | off | Clear the session before each request |
| `chat_command` | `hermes chat --resume {session}` | Command for the Chat button |
| `language` | `en` | UI language (en/ru) |

## Docker (Hermes in a container)

The plugin works with Hermes in Docker — two settings to adjust:

1. **`env_file`** → path to the compose `.env` on the host (where `API_SERVER_KEY` lives):
   ```
   ~/hermes-workspace/.env
   ```
   Without a key, sessions fail with 401/403 — the plugin shows a clear error.

2. **`chat_command`** → chat launch through the container:
   ```
   docker exec -it hermes-agent hermes chat --resume {session}
   ```

Make sure port 8642 is published in docker-compose (`ports: 8642:8642`) and `API_SERVER_KEY` is set in `.env`.

## Commands

`commands.json` format:

```json
[
  {
    "name": "Explain this",
    "prompt": "Explain the text in triple quotes below:\n\"\"\"\n{input}\n\"\"\"",
    "name_ru": "Объясни это",
    "prompt_ru": "Объясни текст в тройных кавычках ниже:\n\"\"\"\n{input}\n\"\"\"",
    "ask": false
  }
]
```

- `{input}` — the selected text (or the typed question for `ask` commands)
- `name_ru` / `prompt_ru` — Russian variants (used when `language=ru`)
- `ask: true` — free-question command: Enter opens an input field

## Hermes sessions

- The plugin always uses one session `ai-menu` (header `X-Hermes-Session-Id`).
- `clear_session=on`: session history is deleted before each request via `DELETE /api/sessions/ai-menu` — no new sessions are created.
- The **Chat** button opens a terminal with `hermes chat --resume ai-menu` — the same session.

## Localization

- **Panel UI** (commands, buttons, hints, errors): switches with the `language` setting (`en` default).
- **Plugin settings in the Noctalia GUI** (label_key in plugin.toml): localized by **Noctalia's own language** (`lang` in `~/.config/noctalia/config.toml`) via `translations/<lang>.json`. To have English settings, set `lang = "en"` in the Noctalia config.
- Commands support `name_ru`/`prompt_ru` — Russian prompts are used when `language=ru`.

## Architecture

```
shortcut.luau ──toggle──▶ panel.luau ──HTTP stream──▶ Hermes API
                             │  ▲
                             │  │ state channel "paste"
                             ▼  │
                          service.luau (deferred wtype paste)
```

- **panel.luau**: UI, phases (list/ask/working/done), `noctalia.httpStream` (SSE), `delta.content` accumulation, tool.progress
- **service.luau**: after the panel closes, emulates Ctrl+V via `wtype`; for Insert restores the previous clipboard
- **shortcut.luau**: control-center tile that opens the panel

### Streaming (how it works)

1. Request is sent with `stream: true` via `noctalia.httpStream`
2. SSE lines `data: {delta.content}` accumulate into `response` and render live
3. `event: hermes.tool.progress` + `data: {tool, emoji, label}` — tool status ("🐍 python3 …")
4. `data: [DONE]` → finalization → DONE phase with action buttons
5. Closing the panel mid-response → `handle.stop()` cancels the stream

## Requirements

- Wayland + Noctalia v5 (plugin_api 24)
- `wl-paste` / `wl-copy` (wl-clipboard), `wtype`
- Hermes API on `base_url` (port 8642)

## License

MIT
