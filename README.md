# Remote Terminal via Telegram

Control any Claude Code terminal session remotely via Telegram. Mirror terminal output, send commands, approve/reject actions, and use voice input — all from your phone.

## Features

- **Two-way sync**: Terminal output → Telegram, Telegram input → Terminal
- **Smart formatting**: Code diffs with syntax highlighting (green/red), tables as mobile-friendly cards, bash commands in code blocks
- **Approval workflow**: Approve/reject Claude Code actions from Telegram with one tap
- **Voice input**: Send voice messages, review transcription, then send to terminal
- **Self-editing messages**: Terminal output updates in-place (no message spam)
- **Persistent keyboard**: One-tap Yes/No/Escape/Status/Continue buttons
- **Works with ANY project**: Fully config-driven, not hardcoded to any specific project
- **Minimized window support**: Works even when Terminal.app is minimized

## Prerequisites

- macOS with Terminal.app (uses AppleScript for terminal interaction)
- Python 3.x
- [Claude Code CLI](https://claude.ai/code) installed
- A Telegram account
- ffmpeg (for voice input): `brew install ffmpeg`

## Quick Start

```bash
# 1. Clone the repo
git clone https://github.com/yourusername/remote-terminal-via-telegram.git
cd remote-terminal-via-telegram

# 2. Create a Telegram bot via @BotFather and get your bot token

# 3. Run the setup wizard
./setup.sh

# 4. In your project's terminal, launch Claude Code and type:
/terminal-control-start
```

## Setup

### 1. Create a Telegram Bot

1. Open Telegram and message `@BotFather`
2. Send `/newbot`
3. Choose a name and username
4. Save the bot token (format: `1234567890:ABCdef...`)

### 2. Run Setup Wizard

```bash
./setup.sh
```

The wizard will:
- Validate your bot token
- Auto-detect your Chat ID (send a message to your bot when prompted)
- Configure your project name and working directory
- Set up voice transcription (local mlx-whisper or OpenAI API)
- Install Claude Code slash commands into your project
- Send a test message to verify everything works

### 3. Grant Accessibility Permission

For Telegram → Terminal keystroke injection:
- **System Settings → Privacy & Security → Accessibility**
- Enable **Terminal.app**

### 4. Start Using

In your project's Claude Code session:
```
/terminal-control-start
```

## Button Reference

| Button | Action | When to use |
|--------|--------|-------------|
| **✅ 1. Yes** | Types `1` | Approve a tool/edit/command, or approve voice transcription |
| **✅ 2. Always** | Types `2` | Approve and don't ask again for this tool type |
| **❌ 3. No** | Types `3` | Reject a tool/edit/command, or cancel voice transcription |
| **🛑 Esc (cancel)** | Sends Escape | Interrupt Claude mid-action |
| **📋 Status** | Asks for status | Get a progress update from Claude |
| **🔄 Continue** | Continue prompt | Tell Claude to keep going |
| **↩️ Undo last change** | Undo request | Ask Claude to revert last edit |
| **⏹ /terminal-control-end** | Stop session | Disconnect bot from terminal |

## Voice Input

Send a voice message in Telegram:

1. **🎙 Transcribing...** — processing notification
2. Bot shows the transcribed text
3. Press **✅ 1. Yes** to send to terminal, or **❌ 3. No** to cancel

### Voice Backends

| Backend | Speed | Cost | Setup |
|---------|-------|------|-------|
| **mlx-whisper** | ~2-3s | Free | Automatic (setup.sh installs it) |
| **OpenAI Whisper API** | ~1s | $0.006/min | Requires API key |

## Telegram Message Formatting

The bot formats terminal output for mobile readability:

- **Code diffs** → `diff` syntax with line numbers and green/red highlighting
- **Bash commands** → `bash` code blocks with separate output blocks
- **Tables** → Converted to labeled card format
- **File edits** → Language-specific syntax highlighting (TypeScript, Python, JSON, etc.)
- **Approval prompts** → Full context with code preview and action buttons
- **Status indicators** → 🪸 for timing, 🧑 for user, 🤖 for Claude

## Configuration

All settings are stored in `config.json` (created by `setup.sh`):

```json
{
  "telegram": {
    "bot_token": "your-bot-token",
    "chat_id": "your-chat-id",
    "allowed_user_id": "your-telegram-user-id"
  },
  "project": {
    "name": "Terminal",
    "working_directory": "",
    "window_match_string": ""
  },
  "voice": {
    "backend": "mlx-whisper",
    "mlx_model": "mlx-community/whisper-tiny.en-mlx",
    "openai_api_key": ""
  }
}
```

### Project Settings

- **`name`**: Display name in Telegram messages (e.g., "MyApp Terminal")
- **`working_directory`**: Optional. If set, slash commands are also installed there
- **`window_match_string`**: Optional. If empty, the bot controls **any** Claude Code terminal window. If set (e.g., "MyApp"), it only matches Terminal windows with that string in the title

### Switching Projects

No reconfiguration needed — if `window_match_string` is empty, the bot automatically follows whichever Claude Code terminal is active. Just `cd` to a different project and the bot keeps working.

## Security: macOS Keychain (Optional)

During setup, you can choose to store sensitive credentials (bot token, OpenAI API key) in macOS Keychain instead of `config.json`.

**With Keychain enabled:**
- Bot token and API keys are stored in your login Keychain
- `config.json` contains `"STORED_IN_KEYCHAIN"` placeholder instead of actual secrets
- Credentials are retrieved at runtime via the `security` command
- Even if `config.json` is leaked, no secrets are exposed

**Without Keychain:**
- Everything stored in `config.json` with `chmod 600` (owner-only read)
- Simpler but less secure

To switch an existing setup to Keychain:
```bash
# Store token in Keychain manually
security add-generic-password -U -s "remote-terminal-telegram" -a "bot_token" -w "YOUR_TOKEN"

# Edit config.json: set security.use_keychain to true
# and bot_token to "STORED_IN_KEYCHAIN"
```

## Architecture

```
┌─────────────────┐         ┌──────────────────┐
│  Terminal.app    │         │  Telegram Bot API │
│  (Claude Code)   │         │                  │
└────────┬────────┘         └────────┬─────────┘
         │                           │
    ┌────┴────┐                 ┌────┴────┐
    │ terminal│ AppleScript     │  poll.sh │ HTTP polling
    │ watcher │ reads content   │         │ reads messages
    │  .py    │────────────────►│         │
    │         │  sends to TG    │         │────────────────►
    └─────────┘                 │         │ types into terminal
                                │         │ via type-to-terminal.sh
                                └─────────┘
```

## Files

| File | Purpose |
|------|---------|
| `setup.sh` | Interactive setup wizard |
| `config.json` | All settings (gitignored) |
| `config.example.json` | Template for config |
| `scripts/load-config.sh` | Shared config loader |
| `scripts/start.sh` | Activate session |
| `scripts/stop.sh` | Deactivate session |
| `scripts/poll.sh` | Telegram → Terminal daemon |
| `scripts/terminal-watcher.py` | Terminal → Telegram daemon |
| `scripts/type-to-terminal.sh` | AppleScript keystroke injection |
| `scripts/transcribe-voice.sh` | Voice transcription (mlx-whisper / OpenAI) |
| `scripts/send.sh` | Send a Telegram message |
| `scripts/check-inbox.sh` | Check for incoming messages |
| `commands/` | Claude Code slash command templates |

## License

MIT
