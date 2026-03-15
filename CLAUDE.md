# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Remote Terminal via Telegram — a bridge between Claude Code terminal sessions and Telegram. Mirrors terminal output, sends commands, handles approvals, and supports voice input. Works with any project — fully config-driven.

## Commands

```bash
./setup.sh                    # Interactive setup wizard
./scripts/start.sh            # Activate Telegram sync
./scripts/stop.sh             # Deactivate Telegram sync
./scripts/send.sh "message"   # Send a Telegram message
./scripts/check-inbox.sh      # Check for incoming Telegram messages
```

## Architecture

- **config.json** — All settings (Telegram token, project name, window match, voice backend)
- **scripts/load-config.sh** — Shared config loader sourced by all scripts
- **scripts/poll.sh** — Telegram → Terminal (polls for messages, types into terminal)
- **scripts/terminal-watcher.py** — Terminal → Telegram (reads terminal via AppleScript, sends formatted updates)
- **scripts/type-to-terminal.sh** — AppleScript keystroke injection
- **scripts/transcribe-voice.sh** — Voice message transcription (mlx-whisper or OpenAI)
- **scripts/start.sh / stop.sh** — Session lifecycle management
- **commands/** — Claude Code slash command templates

## Config

All settings in `config.json` (created by `setup.sh`). No hardcoded paths, tokens, or project names in any script.
