#!/bin/bash
# Loads config.json and exports variables for all scripts
# Supports optional macOS Keychain for sensitive values (bot_token, openai_api_key)
# Usage: source "$SCRIPT_DIR/load-config.sh"

RTVT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$RTVT_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.json not found. Run ./setup.sh first." >&2
  exit 1
fi

_RTVT_CONFIG_TMP=$(mktemp)
trap 'rm -f "$_RTVT_CONFIG_TMP"' RETURN

export _RTVT_CONFIG_FILE="$CONFIG_FILE"
python3 -c '
import json, shlex, os, subprocess, sys

config_file = os.environ["_RTVT_CONFIG_FILE"]
with open(config_file) as f:
    c = json.load(f)

use_keychain = c.get("security", {}).get("use_keychain", False) and sys.platform == "darwin"

def get_from_keychain(service, account):
    """Retrieve a secret from macOS Keychain (macOS only)."""
    if sys.platform != "darwin":
        return None
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", service, "-a", account, "-w"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None

# Get bot token: keychain first, then config fallback
bot_token = ""
openai_key = ""

if use_keychain:
    bot_token = get_from_keychain("remote-terminal-telegram", "bot_token") or ""
    openai_key = get_from_keychain("remote-terminal-telegram", "openai_api_key") or ""

if not bot_token:
    bot_token = c["telegram"].get("bot_token", "")
if not openai_key:
    openai_key = c["voice"].get("openai_api_key", "")

# Fail clearly if token is still a placeholder
if bot_token == "STORED_IN_KEYCHAIN":
    print("echo \"ERROR: Bot token not found in Keychain. Run: security add-generic-password -U -s remote-terminal-telegram -a bot_token -w YOUR_TOKEN\" >&2; exit 1")
    sys.exit(1)
if not bot_token:
    print("echo \"ERROR: Bot token is empty. Run setup.sh or check config.json\" >&2; exit 1")
    sys.exit(1)
if openai_key == "STORED_IN_KEYCHAIN":
    openai_key = ""  # Non-critical — just disable voice

exports = {
    "TELEGRAM_BOT_TOKEN": bot_token,
    "TELEGRAM_CHAT_ID": str(c["telegram"]["chat_id"]),
    "ALLOWED_USER_ID": str(c["telegram"].get("allowed_user_id", c["telegram"]["chat_id"])),
    "PROJECT_NAME": c.get("project", {}).get("name", "Terminal"),
    "PROJECT_DIR": c.get("project", {}).get("working_directory", ""),
    "WINDOW_MATCH": c.get("project", {}).get("window_match_string", ""),
    "TMUX_SESSION": c.get("project", {}).get("tmux_session", ""),
    "VOICE_BACKEND": c["voice"]["backend"],
    "MLX_MODEL": c["voice"]["mlx_model"],
    "OPENAI_API_KEY": openai_key,
}
for key, val in exports.items():
    print(f"export {key}={shlex.quote(val)}")
' > "$_RTVT_CONFIG_TMP" 2>/dev/null

if [ $? -ne 0 ]; then
  echo "ERROR: Failed to parse config.json" >&2
  rm -f "$_RTVT_CONFIG_TMP"
  exit 1
fi

source "$_RTVT_CONFIG_TMP"
unset _RTVT_CONFIG_FILE
export RTVT_DIR
