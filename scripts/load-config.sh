#!/usr/bin/env bash
# Loads config.json and exports variables for all scripts
# Supports optional macOS Keychain and Linux secret-tool for sensitive values
# Secrets are written to a chmod-600 temp file sourced once, then deleted —
# they are exported as env vars for the current process tree only.
# Usage: source "$SCRIPT_DIR/load-config.sh"

RTVT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$RTVT_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.json not found. Run ./setup.sh first." >&2
  exit 1
fi

_RTVT_CONFIG_TMP=$(mktemp)
chmod 600 "$_RTVT_CONFIG_TMP"
# Clean up temp file after sourcing (RETURN works when script is sourced)
trap 'rm -f "$_RTVT_CONFIG_TMP"' RETURN 2>/dev/null || trap 'rm -f "$_RTVT_CONFIG_TMP"' EXIT

export _RTVT_CONFIG_FILE="$CONFIG_FILE"
python3 -c '
import json, shlex, os, subprocess, sys

config_file = os.environ["_RTVT_CONFIG_FILE"]
with open(config_file) as f:
    c = json.load(f)

use_keychain = c.get("security", {}).get("use_keychain", False)
use_secret_tool = c.get("security", {}).get("use_secret_tool", False) and sys.platform == "linux"

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

def get_from_secret_tool(service, account):
    """Retrieve a secret from GNOME Keyring / libsecret (Linux only)."""
    if sys.platform != "linux":
        return None
    try:
        result = subprocess.run(
            ["secret-tool", "lookup", "service", service, "account", account],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return None

# Get bot token: keychain/secret-tool first, then config fallback
bot_token = ""
openai_key = ""

if use_keychain and sys.platform == "darwin":
    bot_token = get_from_keychain("remote-terminal-telegram", "bot_token") or ""
    openai_key = get_from_keychain("remote-terminal-telegram", "openai_api_key") or ""
elif use_secret_tool:
    bot_token = get_from_secret_tool("remote-terminal-telegram", "bot_token") or ""
    openai_key = get_from_secret_tool("remote-terminal-telegram", "openai_api_key") or ""

if not bot_token or bot_token == "STORED_IN_KEYCHAIN" or bot_token == "STORED_IN_SECRET_TOOL":
    bot_token = c["telegram"].get("bot_token", "")
if not openai_key or openai_key in ("STORED_IN_KEYCHAIN", "STORED_IN_SECRET_TOOL"):
    openai_key = c["voice"].get("openai_api_key", "")

# Fail clearly if token is still a placeholder
if bot_token in ("STORED_IN_KEYCHAIN", "STORED_IN_SECRET_TOOL"):
    if sys.platform == "darwin":
        print("echo \"ERROR: Bot token not found in Keychain. Run: security add-generic-password -U -s remote-terminal-telegram -a bot_token -w YOUR_TOKEN\" >&2; exit 1")
    else:
        print("echo \"ERROR: Bot token not found in secret-tool. Run: secret-tool store --label=RTVT service remote-terminal-telegram account bot_token\" >&2; exit 1")
    sys.exit(1)
if not bot_token:
    print("echo \"ERROR: Bot token is empty. Run setup.sh or check config.json\" >&2; exit 1")
    sys.exit(1)
if openai_key in ("STORED_IN_KEYCHAIN", "STORED_IN_SECRET_TOOL"):
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
