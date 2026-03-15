#!/bin/bash
# Stop Remote Terminal — deactivates Telegram sync
# Security: PID-based cleanup, token hidden from ps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

LOG_FILE="$RTVT_DIR/daemon.log"

# Send shutdown message (hide token)
_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" > "$_URL_FILE"
curl -s -K "$_URL_FILE" \
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
rm -f "$_URL_FILE"

# Deactivate
rm -f "$RTVT_DIR/.active"

# Kill daemons via PID files
for pidfile in "$RTVT_DIR/.poll.pid" "$RTVT_DIR/.watcher.pid"; do
  if [ -f "$pidfile" ]; then
    OLD_PID=$(cat "$pidfile")
    kill "$OLD_PID" 2>/dev/null || true
    sleep 0.5
    kill -9 "$OLD_PID" 2>/dev/null || true
    rm -f "$pidfile"
  fi
done
rm -rf "$RTVT_DIR/.poll.lock"
rm -f "$RTVT_DIR/inbox"/*.txt 2>/dev/null || true

echo "$(date '+%Y-%m-%d %H:%M:%S') Session stopped" >> "$LOG_FILE"
echo "🔴 Remote Terminal deactivated"
