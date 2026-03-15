#!/bin/bash
# Loads config.json and exports variables for all scripts
# Usage: source "$SCRIPT_DIR/load-config.sh"

RTVT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_FILE="$RTVT_DIR/config.json"

if [ ! -f "$CONFIG_FILE" ]; then
  echo "ERROR: config.json not found. Run ./setup.sh first." >&2
  exit 1
fi

eval "$(python3 -c "
import json, sys
try:
    with open('$CONFIG_FILE') as f:
        c = json.load(f)
    print(f'export TELEGRAM_BOT_TOKEN=\"{c[\"telegram\"][\"bot_token\"]}\"')
    print(f'export TELEGRAM_CHAT_ID=\"{c[\"telegram\"][\"chat_id\"]}\"')
    print(f'export PROJECT_NAME=\"{c[\"project\"][\"name\"]}\"')
    print(f'export PROJECT_DIR=\"{c[\"project\"][\"working_directory\"]}\"')
    print(f'export WINDOW_MATCH=\"{c[\"project\"][\"window_match_string\"]}\"')
    print(f'export VOICE_BACKEND=\"{c[\"voice\"][\"backend\"]}\"')
    print(f'export MLX_MODEL=\"{c[\"voice\"][\"mlx_model\"]}\"')
    print(f'export OPENAI_API_KEY=\"{c[\"voice\"].get(\"openai_api_key\", \"\")}\"')
except Exception as e:
    print(f'echo \"ERROR: Failed to load config: {e}\" >&2; exit 1', file=sys.stderr)
    sys.exit(1)
" 2>/dev/null)"

export RTVT_DIR
