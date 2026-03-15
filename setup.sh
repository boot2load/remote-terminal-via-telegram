#!/usr/bin/env bash
# Remote Terminal via Telegram — Interactive Setup Wizard
# Creates config.json and installs everything needed

set -euo pipefail

RTVT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "╔══════════════════════════════════════════╗"
echo "║  Remote Terminal via Telegram — Setup    ║"
echo "╚══════════════════════════════════════════╝"
echo ""

# --- Detect OS ---
OS_TYPE="$(uname -s)"
echo "Platform: $OS_TYPE"
echo ""

# --- Prerequisites ---
echo "Checking prerequisites..."
command -v python3 >/dev/null || { echo "❌ python3 not found. Install Python 3.6+."; exit 1; }
python3 -c "import sys; assert sys.version_info >= (3,6), 'Python 3.6+ required'" 2>/dev/null || { echo "❌ Python 3.6+ required."; exit 1; }
command -v curl >/dev/null || { echo "❌ curl not found."; exit 1; }

if [ "$OS_TYPE" = "Darwin" ]; then
  command -v osascript >/dev/null || { echo "⚠️  osascript not found. Terminal.app integration won't work."; }
  command -v ffmpeg >/dev/null || echo "⚠️  ffmpeg not found. Voice input will not work. Install: brew install ffmpeg"
elif [ "$OS_TYPE" = "Linux" ]; then
  command -v tmux >/dev/null || { echo "❌ tmux not found. Required on Linux. Install: sudo apt install tmux"; exit 1; }
  command -v ffmpeg >/dev/null || echo "⚠️  ffmpeg not found. Voice input will not work. Install: sudo apt install ffmpeg"
elif [[ "$OS_TYPE" == MINGW* ]] || [[ "$OS_TYPE" == MSYS* ]] || [[ "$OS_TYPE" == CYGWIN* ]]; then
  command -v powershell.exe >/dev/null || { echo "❌ powershell.exe not found. Required on Windows."; exit 1; }
  command -v ffmpeg >/dev/null || echo "⚠️  ffmpeg not found. Voice input will not work. Install: winget install ffmpeg"
fi
echo "✅ Prerequisites OK"
echo ""

# --- Telegram Bot Token ---
echo "Step 1: Telegram Bot"
echo "  Create a bot via @BotFather in Telegram if you haven't already."
echo ""
read -rp "  Enter your Telegram bot token: " BOT_TOKEN

# Validate token (hide from ps)
_SETUP_URL=$(mktemp)
chmod 600 "$_SETUP_URL"
echo "url = \"https://api.telegram.org/bot${BOT_TOKEN}/getMe\"" > "$_SETUP_URL"
BOT_INFO=$(curl -s -K "$_SETUP_URL" 2>/dev/null)
BOT_OK=$(echo "$BOT_INFO" | python3 -c "import sys,json; print(json.load(sys.stdin).get('ok',False))" 2>/dev/null || echo "False")
if [ "$BOT_OK" != "True" ]; then
  echo "  ❌ Invalid bot token. Check and try again."
  rm -f "$_SETUP_URL"
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
SENDER_NAME=""
USER_ID=""
for i in $(seq 1 30); do
  echo "url = \"https://api.telegram.org/bot${BOT_TOKEN}/getUpdates\"" > "$_SETUP_URL"
  UPDATES=$(curl -s -K "$_SETUP_URL" 2>/dev/null)
  RESULT=$(echo "$UPDATES" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for u in data.get('result', []):
    msg = u.get('message', {})
    chat = msg.get('chat', {})
    sender = msg.get('from', {})
    if chat.get('id'):
        name = sender.get('first_name', '') + ' ' + sender.get('last_name', '')
        username = sender.get('username', '')
        print(f'{chat[\"id\"]}|{sender.get(\"id\", chat[\"id\"])}|{name.strip()}|{username}')
        break
" 2>/dev/null || echo "")
  if [ -n "$RESULT" ]; then
    CHAT_ID=$(echo "$RESULT" | cut -d'|' -f1)
    USER_ID=$(echo "$RESULT" | cut -d'|' -f2)
    SENDER_NAME=$(echo "$RESULT" | cut -d'|' -f3)
    SENDER_USERNAME=$(echo "$RESULT" | cut -d'|' -f4)
    break
  fi
  sleep 2
done

if [ -z "$CHAT_ID" ]; then
  echo "  ❌ No message received. Send a message to @${BOT_NAME} and try again."
  rm -f "$_SETUP_URL"
  exit 1
fi
echo ""
echo "  Detected sender: ${SENDER_NAME} (@${SENDER_USERNAME})"
echo "  Chat ID: ${CHAT_ID}"
echo "  User ID: ${USER_ID}"
read -rp "  Is this you? (y/n): " CONFIRM_SENDER
if [ "$CONFIRM_SENDER" != "y" ]; then
  echo "  ❌ Aborted. Run setup again after messaging the bot."
  rm -f "$_SETUP_URL"
  exit 1
fi
echo "  ✅ Sender confirmed"
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

if [ "$OS_TYPE" = "Darwin" ]; then
  echo "  Window match string: restricts the bot to a specific Terminal window."
  echo "  Leave blank to control ANY Claude Code terminal (recommended)."
  read -rp "  Window match string (blank = any Claude Code window): " WINDOW_MATCH
elif [ "$OS_TYPE" = "Linux" ]; then
  WINDOW_MATCH=""
  echo "  tmux session: restricts the bot to a specific tmux session."
  echo "  Leave blank to auto-detect the Claude Code pane (recommended)."
  read -rp "  tmux session name (blank = auto-detect): " TMUX_SESSION_NAME
else
  # Windows
  echo "  Window match string: restricts the bot to a specific terminal window."
  echo "  Leave blank to control ANY Claude Code window (recommended)."
  read -rp "  Window match string (blank = any Claude Code window): " WINDOW_MATCH
fi
echo ""

# --- Voice ---
echo "Step 4: Voice Input"
VOICE_BACKEND="none"
MLX_MODEL="mlx-community/whisper-tiny.en-mlx"
OPENAI_KEY=""

if [ "$OS_TYPE" = "Darwin" ]; then
  echo "  1) mlx-whisper (local, Apple Silicon, free)"
  echo "  2) OpenAI Whisper API (cloud, fast, requires API key)"
  echo "  3) None (disable voice input)"
  read -rp "  Choose (1/2/3): " VOICE_CHOICE
  case "$VOICE_CHOICE" in
    1) VOICE_BACKEND="mlx-whisper"
       read -rp "  MLX model (default: ${MLX_MODEL}): " MLX_INPUT
       MLX_MODEL="${MLX_INPUT:-$MLX_MODEL}" ;;
    2) VOICE_BACKEND="openai"
       read -rp "  OpenAI API key: " OPENAI_KEY ;;
    3) VOICE_BACKEND="none" ;;
  esac
else
  echo "  1) OpenAI Whisper API (cloud, fast, requires API key)"
  echo "  2) None (disable voice input)"
  read -rp "  Choose (1/2): " VOICE_CHOICE
  case "$VOICE_CHOICE" in
    1) VOICE_BACKEND="openai"
       read -rp "  OpenAI API key: " OPENAI_KEY ;;
    *) VOICE_BACKEND="none" ;;
  esac
fi
echo ""

# --- Security: Credential Storage ---
USE_KEYCHAIN=false
USE_SECRET_TOOL=false
if [ "$OS_TYPE" = "Darwin" ]; then
  echo "Step 5: Credential Storage"
  echo "  1) macOS Keychain (recommended — secrets stored securely, not in files)"
  echo "  2) Config file only (secrets in config.json with 600 permissions)"
  read -rp "  Choose (1/2): " KEYCHAIN_CHOICE

  if [ "$KEYCHAIN_CHOICE" = "1" ]; then
    USE_KEYCHAIN=true
    echo "  Storing bot token in macOS Keychain..."
    security add-generic-password -U -s "remote-terminal-telegram" -a "bot_token" -w "$BOT_TOKEN" 2>/dev/null
    echo "  ✅ Bot token stored in Keychain"

    if [ -n "$OPENAI_KEY" ]; then
      security add-generic-password -U -s "remote-terminal-telegram" -a "openai_api_key" -w "$OPENAI_KEY" 2>/dev/null
      echo "  ✅ OpenAI API key stored in Keychain"
    fi
  fi
elif [[ "$OS_TYPE" == MINGW* ]] || [[ "$OS_TYPE" == MSYS* ]] || [[ "$OS_TYPE" == CYGWIN* ]]; then
  echo "Step 5: Credential Storage"
  echo "  Credentials will be stored in config.json (file permissions restricted)"
  echo "  Windows Credential Manager integration is not yet supported."
else
  echo "Step 5: Credential Storage"
  if command -v secret-tool >/dev/null 2>&1; then
    echo "  1) GNOME Keyring / secret-tool (recommended — secrets stored securely)"
    echo "  2) Config file only (secrets in config.json with 600 permissions)"
    read -rp "  Choose (1/2): " LINUX_CRED_CHOICE
    if [ "$LINUX_CRED_CHOICE" = "1" ]; then
      USE_SECRET_TOOL=true
      echo "  Storing bot token in GNOME Keyring..."
      echo -n "$BOT_TOKEN" | secret-tool store --label="RTVT Bot Token" service remote-terminal-telegram account bot_token 2>/dev/null
      echo "  ✅ Bot token stored in GNOME Keyring"
      if [ -n "$OPENAI_KEY" ]; then
        echo -n "$OPENAI_KEY" | secret-tool store --label="RTVT OpenAI Key" service remote-terminal-telegram account openai_api_key 2>/dev/null
        echo "  ✅ OpenAI API key stored in GNOME Keyring"
      fi
    fi
  else
    echo "  Credentials will be stored in config.json (file permissions: 600)"
    echo "  Tip: install libsecret-tools for secure credential storage"
  fi
fi
echo ""

# --- Write config (values passed via env vars to prevent injection) ---
echo "Writing config.json..."
export _CFG_BOT_TOKEN="$BOT_TOKEN"
export _CFG_CHAT_ID="$CHAT_ID"
export _CFG_USER_ID="$USER_ID"
export _CFG_PROJECT_NAME="$PROJECT_NAME"
export _CFG_PROJECT_DIR="$PROJECT_DIR"
export _CFG_WINDOW_MATCH="${WINDOW_MATCH:-}"
export _CFG_TMUX_SESSION="${TMUX_SESSION_NAME:-}"
export _CFG_VOICE_BACKEND="$VOICE_BACKEND"
export _CFG_MLX_MODEL="$MLX_MODEL"
export _CFG_OPENAI_KEY="$OPENAI_KEY"
export _CFG_USE_KEYCHAIN="$USE_KEYCHAIN"
export _CFG_USE_SECRET_TOOL="${USE_SECRET_TOOL:-false}"
export _CFG_OUTPUT="$RTVT_DIR/config.json"

python3 -c '
import json, os

use_keychain = os.environ.get("_CFG_USE_KEYCHAIN") == "true"

config = {
    "telegram": {
        "chat_id": int(os.environ["_CFG_CHAT_ID"]),
        "allowed_user_id": int(os.environ.get("_CFG_USER_ID", os.environ["_CFG_CHAT_ID"]))
    },
    "project": {
        "name": os.environ["_CFG_PROJECT_NAME"],
        "working_directory": os.environ["_CFG_PROJECT_DIR"],
        "window_match_string": os.environ["_CFG_WINDOW_MATCH"],
        "tmux_session": os.environ.get("_CFG_TMUX_SESSION", "")
    },
    "voice": {
        "backend": os.environ["_CFG_VOICE_BACKEND"],
        "mlx_model": os.environ["_CFG_MLX_MODEL"],
    },
    "security": {
        "use_keychain": use_keychain,
        "use_secret_tool": os.environ.get("_CFG_USE_SECRET_TOOL") == "true"
    }
}

# Only store secrets in config if NOT using a secure store
use_secret_tool = config["security"].get("use_secret_tool", False)
if not use_keychain and not use_secret_tool:
    config["telegram"]["bot_token"] = os.environ["_CFG_BOT_TOKEN"]
    config["voice"]["openai_api_key"] = os.environ.get("_CFG_OPENAI_KEY", "")
elif use_keychain:
    config["telegram"]["bot_token"] = "STORED_IN_KEYCHAIN"
    config["voice"]["openai_api_key"] = "STORED_IN_KEYCHAIN"
elif use_secret_tool:
    config["telegram"]["bot_token"] = "STORED_IN_SECRET_TOOL"
    config["voice"]["openai_api_key"] = "STORED_IN_SECRET_TOOL"

with open(os.environ["_CFG_OUTPUT"], "w") as f:
    json.dump(config, f, indent=2)
print("✅ config.json written")
'
chmod 600 "$RTVT_DIR/config.json"

# Clean up env vars
unset _CFG_BOT_TOKEN _CFG_CHAT_ID _CFG_USER_ID _CFG_PROJECT_NAME _CFG_PROJECT_DIR
unset _CFG_WINDOW_MATCH _CFG_TMUX_SESSION _CFG_VOICE_BACKEND _CFG_MLX_MODEL _CFG_OPENAI_KEY
unset _CFG_USE_KEYCHAIN _CFG_USE_SECRET_TOOL _CFG_OUTPUT

# --- Python venv ---
if [ "$VOICE_BACKEND" = "mlx-whisper" ]; then
  echo "Setting up Python venv for mlx-whisper..."
  python3 -m venv "$RTVT_DIR/.venv"
  "$RTVT_DIR/.venv/bin/pip" install 'mlx-whisper>=0.4.0,<1.0.0' -q 2>&1 | tail -1
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
echo "url = \"https://api.telegram.org/bot${BOT_TOKEN}/sendMessage\"" > "$_SETUP_URL"
curl -s -K "$_SETUP_URL" \
  -d chat_id="${CHAT_ID}" \
  --data-urlencode "text=🟢 Remote Terminal via Telegram is configured for ${PROJECT_NAME}!" \
  > /dev/null
rm -f "$_SETUP_URL"
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
