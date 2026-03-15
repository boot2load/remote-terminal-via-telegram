#!/bin/bash
# Stop Remote Terminal — deactivates Telegram sync
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

# Send shutdown message with inactive keyboard
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
    \"text\": \"🔴 *Remote Terminal Deactivated*\n${PROJECT_NAME} session monitoring stopped.\nRun /terminal-control-start to reconnect.\",
    \"parse_mode\": \"Markdown\",
    \"reply_markup\": {
      \"keyboard\": [
        [{\"text\": \"⬜ Not connected to terminal\"}],
        [{\"text\": \"▶️ /terminal-control-start\"}]
      ],
      \"resize_keyboard\": true,
      \"is_persistent\": true
    }
  }" > /dev/null

# Deactivate
rm -f "$RTVT_DIR/.active"
pkill -9 -f "$RTVT_DIR/scripts/poll.sh" 2>/dev/null || true
pkill -9 -f "$RTVT_DIR/scripts/terminal-watcher.py" 2>/dev/null || true
rm -f "$RTVT_DIR/.poll.pid" "$RTVT_DIR/.watcher.pid"
rm -f "$RTVT_DIR/inbox"/*.txt 2>/dev/null || true

echo "🔴 Remote Terminal deactivated"
