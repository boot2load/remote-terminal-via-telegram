#!/bin/bash
# Loads config.json and exports variables for all scripts
# Usage: source "$SCRIPT_DIR/load-config.sh"
# Security: uses shlex.quote() to prevent shell injection from config values

RTVT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$RTVT_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.json not found. Run ./setup.sh first." >&2
  exit 1
fi

# Write safe exports to a temp file — never use eval with raw config values
_RTVT_CONFIG_TMP=$(mktemp)
trap 'rm -f "$_RTVT_CONFIG_TMP"' RETURN

export _RTVT_CONFIG_FILE="$CONFIG_FILE"
python3 -c '
import json, shlex, os, sys

config_file = os.environ["_RTVT_CONFIG_FILE"]
with open(config_file) as f:
    c = json.load(f)

exports = {
    "TELEGRAM_BOT_TOKEN": c["telegram"]["bot_token"],
    "TELEGRAM_CHAT_ID": str(c["telegram"]["chat_id"]),
    "ALLOWED_USER_ID": str(c["telegram"].get("allowed_user_id", c["telegram"]["chat_id"])),
    "PROJECT_NAME": c.get("project", {}).get("name", "Terminal"),
    "PROJECT_DIR": c.get("project", {}).get("working_directory", ""),
    "WINDOW_MATCH": c.get("project", {}).get("window_match_string", ""),
    "VOICE_BACKEND": c["voice"]["backend"],
    "MLX_MODEL": c["voice"]["mlx_model"],
    "OPENAI_API_KEY": c["voice"].get("openai_api_key", ""),
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
