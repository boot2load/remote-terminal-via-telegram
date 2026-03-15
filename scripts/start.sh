#!/bin/bash
# Start Remote Terminal — activates two-way Telegram sync
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

# Kill any existing daemons
pkill -9 -f "$RTVT_DIR/scripts/poll.sh" 2>/dev/null || true
pkill -9 -f "$RTVT_DIR/scripts/terminal-watcher.py" 2>/dev/null || true
rm -f "$RTVT_DIR/.poll.pid" "$RTVT_DIR/.watcher.pid"
sleep 1

# Activate
touch "$RTVT_DIR/.active"
mkdir -p "$RTVT_DIR/inbox"
rm -f "$RTVT_DIR/inbox"/*.txt 2>/dev/null || true

# Set offset to skip old messages
OFFSET=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates" | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(max(u['update_id'] for u in r)+1 if r else 0)" 2>/dev/null || echo "0")
echo "$OFFSET" > "$RTVT_DIR/.last_update_id"

# Start daemons
nohup "$RTVT_DIR/scripts/poll.sh" > /dev/null 2>&1 &
nohup python3 "$RTVT_DIR/scripts/terminal-watcher.py" > /dev/null 2>&1 &

# Send activation message with keyboard
curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H "Content-Type: application/json" \
  -d "{
    \"chat_id\": \"${TELEGRAM_CHAT_ID}\",
    \"text\": \"🟢 *Remote Terminal Activated*\n${PROJECT_NAME} session is now being monitored.\nUse the buttons below or type a message to send to the terminal.\",
    \"parse_mode\": \"Markdown\",
    \"reply_markup\": {
      \"keyboard\": [
        [{\"text\": \"✅ 1. Yes\"}, {\"text\": \"✅ 2. Always\"}, {\"text\": \"❌ 3. No\"}],
        [{\"text\": \"🛑 Esc (cancel)\"}, {\"text\": \"📋 Status\"}, {\"text\": \"🔄 Continue\"}],
        [{\"text\": \"↩️ Undo last change\"}, {\"text\": \"⏹ /terminal-control-end\"}]
      ],
      \"resize_keyboard\": true,
      \"is_persistent\": true
    }
  }" > /dev/null

echo "✅ Remote Terminal activated — Telegram bot is live"
