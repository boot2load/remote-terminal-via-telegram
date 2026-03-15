#!/bin/bash
# Remote Terminal via Telegram — Interactive Setup Wizard
# Creates config.json and installs everything needed

set -euo pipefail

RTVT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║  Remote Terminal via Telegram — Setup    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# --- Prerequisites ---
echo "Checking prerequisites..."
command -v python3 >/dev/null || { echo "❌ python3 not found. Install Python 3."; exit 1; }
command -v osascript >/dev/null || { echo "⚠️  osascript not found. This tool requires macOS Terminal.app."; }
command -v ffmpeg >/dev/null || echo "⚠️  ffmpeg not found. Voice input will not work. Install: brew install ffmpeg"
command -v curl >/dev/null || { echo "❌ curl not found."; exit 1; }
echo "✅ Prerequisites OK"
echo ""

# --- Telegram Bot Token ---
echo "Step 1: Telegram Bot"
echo "  Create a bot via @BotFather in Telegram if you haven't already."
echo ""
read -rp "  Enter your Telegram bot token: " BOT_TOKEN

# Validate token
BOT_INFO=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getMe" 2>/dev/null)
BOT_OK=$(echo "$BOT_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null || echo "False")
if [ "$BOT_OK" != "True" ]; then
  echo "  ❌ Invalid bot token. Check and try again."
  exit 1
fi
BOT_NAME=$(echo "$BOT_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['username'])" 2>/dev/null)
echo "  ✅ Bot: @${BOT_NAME}"
echo ""

# --- Chat ID ---
echo "Step 2: Chat ID"
echo "  Send any message to @${BOT_NAME} in Telegram now..."
echo "  Waiting for your message..."

CHAT_ID=""
for i in $(seq 1 30); do
  UPDATES=$(curl -s "https://api.telegram.org/bot${BOT_TOKEN}/getUpdates" 2>/dev/null)
  CHAT_ID=$(echo "$UPDATES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for u in data.get('result', []):
    msg = u.get('message', {})
    if msg.get('chat', {}).get('id'):
        print(msg['chat']['id'])
        break
" 2>/dev/null || echo "")
  if [ -n "$CHAT_ID" ]; then
    break
  fi
  sleep 2
done

if [ -z "$CHAT_ID" ]; then
  echo "  ❌ No message received. Send a message to @${BOT_NAME} and try again."
  exit 1
fi
echo "  ✅ Chat ID: ${CHAT_ID}"
echo ""

# --- Project Config ---
echo "Step 3: Project (optional — leave blank to work with any Claude Code terminal)"
read -rp "  Display name for Telegram messages (default: Terminal): " PROJECT_NAME
PROJECT_NAME="${PROJECT_NAME:-Terminal}"

read -rp "  Project working directory for slash commands (blank = skip): " PROJECT_DIR

if [ -n "$PROJECT_DIR" ] && [ ! -d "$PROJECT_DIR" ]; then
  echo "  ⚠️  Directory doesn't exist: ${PROJECT_DIR}"
  read -rp "  Continue anyway? (y/n): " CONT
  [ "$CONT" = "y" ] || exit 1
fi

echo "  Window match string: restricts the bot to a specific Terminal window."
echo "  Leave blank to control ANY Claude Code terminal (recommended)."
read -rp "  Window match string (blank = any Claude Code window): " WINDOW_MATCH
echo ""

# --- Voice ---
echo "Step 4: Voice Input"
echo "  1) mlx-whisper (local, Apple Silicon, free)"
echo "  2) OpenAI Whisper API (cloud, fast, requires API key)"
echo "  3) None (disable voice input)"
read -rp "  Choose (1/2/3): " VOICE_CHOICE

VOICE_BACKEND="none"
MLX_MODEL="mlx-community/whisper-tiny.en-mlx"
OPENAI_KEY=""

case "$VOICE_CHOICE" in
  1)
    VOICE_BACKEND="mlx-whisper"
    read -rp "  MLX model (default: ${MLX_MODEL}): " MLX_INPUT
    MLX_MODEL="${MLX_INPUT:-$MLX_MODEL}"
    ;;
  2)
    VOICE_BACKEND="openai"
    read -rp "  OpenAI API key: " OPENAI_KEY
    ;;
  3)
    VOICE_BACKEND="none"
    ;;
esac
echo ""

# --- Write config (values passed via env vars to prevent injection) ---
echo "Writing config.json..."
export _CFG_BOT_TOKEN="$BOT_TOKEN"
export _CFG_CHAT_ID="$CHAT_ID"
export _CFG_PROJECT_NAME="$PROJECT_NAME"
export _CFG_PROJECT_DIR="$PROJECT_DIR"
export _CFG_WINDOW_MATCH="$WINDOW_MATCH"
export _CFG_VOICE_BACKEND="$VOICE_BACKEND"
export _CFG_MLX_MODEL="$MLX_MODEL"
export _CFG_OPENAI_KEY="$OPENAI_KEY"
export _CFG_OUTPUT="$RTVT_DIR/config.json"

python3 -c '
import json, os
config = {
    "telegram": {
        "bot_token": os.environ["_CFG_BOT_TOKEN"],
        "chat_id": os.environ["_CFG_CHAT_ID"],
        "allowed_user_id": os.environ["_CFG_CHAT_ID"]
    },
    "project": {
        "name": os.environ["_CFG_PROJECT_NAME"],
        "working_directory": os.environ["_CFG_PROJECT_DIR"],
        "window_match_string": os.environ["_CFG_WINDOW_MATCH"]
    },
    "voice": {
        "backend": os.environ["_CFG_VOICE_BACKEND"],
        "mlx_model": os.environ["_CFG_MLX_MODEL"],
        "openai_api_key": os.environ.get("_CFG_OPENAI_KEY", "")
    }
}
with open(os.environ["_CFG_OUTPUT"], "w") as f:
    json.dump(config, f, indent=2)
print("✅ config.json written")
'
chmod 600 "$RTVT_DIR/config.json"

# Clean up env vars
unset _CFG_BOT_TOKEN _CFG_CHAT_ID _CFG_PROJECT_NAME _CFG_PROJECT_DIR
unset _CFG_WINDOW_MATCH _CFG_VOICE_BACKEND _CFG_MLX_MODEL _CFG_OPENAI_KEY _CFG_OUTPUT

# --- Python venv ---
if [ "$VOICE_BACKEND" = "mlx-whisper" ]; then
  echo "Setting up Python venv for mlx-whisper..."
  python3 -m venv "$RTVT_DIR/.venv"
  "$RTVT_DIR/.venv/bin/pip" install mlx-whisper -q 2>&1 | tail -1
  echo "  Pre-downloading model..."
  export _MLX_MODEL_DL="$MLX_MODEL"
  "$RTVT_DIR/.venv/bin/python3" -c '
import os
from huggingface_hub import snapshot_download
snapshot_download(os.environ["_MLX_MODEL_DL"])
print("  ✅ Model cached")
' 2>/dev/null || echo "  ⚠️  Model download failed (will download on first use)"
  unset _MLX_MODEL_DL
fi

# --- Install slash commands ---
# Install to user-level Claude commands (works with any project)
echo "Installing Claude Code slash commands..."
mkdir -p "$HOME/.claude/commands"

sed "s|~/remote-terminal-via-telegram|${RTVT_DIR}|g" \
  "$RTVT_DIR/commands/terminal-control-start.md" \
  > "$HOME/.claude/commands/terminal-control-start.md"

sed "s|~/remote-terminal-via-telegram|${RTVT_DIR}|g" \
  "$RTVT_DIR/commands/terminal-control-end.md" \
  > "$HOME/.claude/commands/terminal-control-end.md"

# Also install to specific project if provided
if [ -n "$PROJECT_DIR" ] && [ -d "$PROJECT_DIR" ]; then
  mkdir -p "${PROJECT_DIR}/.claude/commands"
  cp "$HOME/.claude/commands/terminal-control-start.md" "${PROJECT_DIR}/.claude/commands/"
  cp "$HOME/.claude/commands/terminal-control-end.md" "${PROJECT_DIR}/.claude/commands/"
  echo "✅ Slash commands installed (user-level + ${PROJECT_DIR})"
else
  echo "✅ Slash commands installed (user-level — works in any project)"
fi

# --- Make scripts executable ---
chmod +x "$RTVT_DIR"/scripts/*.sh "$RTVT_DIR"/scripts/*.py 2>/dev/null || true

# --- Send test message ---
echo ""
echo "Sending test message to Telegram..."
curl -s -X POST "https://api.telegram.org/bot${BOT_TOKEN}/sendMessage" \
  -d chat_id="${CHAT_ID}" \
  -d text="🟢 Remote Terminal via Telegram is configured for ${PROJECT_NAME}!" \
  > /dev/null
echo "✅ Check your Telegram!"

# --- Summary ---
echo ""
echo "╔══════════════════════════════════════════╗"
echo "║  Setup Complete!                         ║"
echo "╚══════════════════════════════════════════╝"
echo ""
echo "  Bot:       @${BOT_NAME}"
echo "  Name:      ${PROJECT_NAME}"
echo "  Window:    ${WINDOW_MATCH:-any Claude Code terminal}"
echo "  Voice:     ${VOICE_BACKEND}"
echo ""
echo "  To start: launch Claude Code in any project"
echo "  and type /terminal-control-start"
echo ""
