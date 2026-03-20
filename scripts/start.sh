#!/usr/bin/env bash
# Start Remote Terminal — activates two-way Telegram sync
# Security: PID-based process cleanup, token hidden from ps, audit logging
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

LOG_FILE="$RTVT_DIR/daemon.log"

# Kill existing daemons via PID files (not pkill -f)
for pidfile in "$RTVT_DIR/.poll.pid" "$RTVT_DIR/.watcher.pid" "$RTVT_DIR/.watchdog.pid"; do
  if [ -f "$pidfile" ]; then
    OLD_PID=$(cat "$pidfile")
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && [ "$OLD_PID" -gt 1 ] && kill -0 "$OLD_PID" 2>/dev/null; then
      kill "$OLD_PID" 2>/dev/null || true
      # Wait up to 3 seconds for graceful exit
      for _ in 1 2 3 4 5 6; do
        kill -0 "$OLD_PID" 2>/dev/null || break
        sleep 0.5
      done
      # Force kill if still alive
      kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
done
rm -rf "$RTVT_DIR/.poll.lock"
sleep 0.5

# Activate
touch "$RTVT_DIR/.active"
date +%s > "$RTVT_DIR/.session_start"
mkdir -p "$RTVT_DIR/inbox"
chmod 700 "$RTVT_DIR/inbox"
rm -f "$RTVT_DIR/inbox"/*.txt 2>/dev/null || true

# Set offset to skip old messages (hide token from ps)
_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
trap 'rm -f "$_URL_FILE"' EXIT
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates\"" > "$_URL_FILE"
OFFSET=$(curl -s -K "$_URL_FILE" | python3 -c "import sys,json; r=json.load(sys.stdin).get('result',[]); print(max(u['update_id'] for u in r)+1 if r else 0)" 2>/dev/null || echo "0")
echo "$OFFSET" > "$RTVT_DIR/.last_update_id"

# Start daemons with logging
nohup "$RTVT_DIR/scripts/poll.sh" >> "$LOG_FILE" 2>&1 &
nohup python3 "$RTVT_DIR/scripts/terminal-watcher.py" >> "$LOG_FILE" 2>&1 &

# Start watchdog daemon to auto-restart crashed daemons
nohup "$RTVT_DIR/scripts/watchdog.sh" >> "$LOG_FILE" 2>&1 &

# Send activation message with keyboard (hide token, safe JSON via python3)
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" > "$_URL_FILE"
_MSG_JSON=$(python3 -c "
import json, os
name = os.environ.get('PROJECT_NAME', 'Terminal')
# Escape Markdown special characters
for ch in ['_', '*', '[', '\`']:
    name = name.replace(ch, '\\\\' + ch)
print(json.dumps({
    'chat_id': os.environ['TELEGRAM_CHAT_ID'],
    'text': f'🟢 *Remote Terminal Activated*\n{name} session is now being monitored.\nUse the buttons below or type a message to send to the terminal.',
    'parse_mode': 'Markdown',
    'reply_markup': {
        'keyboard': [
            [{'text': '✅ 1. Yes'}, {'text': '✅ 2. Always'}, {'text': '❌ 3. No'}],
            [{'text': '🛑 Esc (cancel)'}, {'text': '📋 Status'}, {'text': '🔄 Continue'}],
            [{'text': '↩️ Undo last change'}, {'text': '⏹ /terminal-control-end'}]
        ],
        'resize_keyboard': True,
        'is_persistent': True
    }
}))
")
curl -s -K "$_URL_FILE" \
  -H "Content-Type: application/json" \
  -d "$_MSG_JSON" > /dev/null

rm -f "$_URL_FILE"

echo "$(date '+%Y-%m-%d %H:%M:%S') Session started for ${PROJECT_NAME}" >> "$LOG_FILE"
echo "✅ Remote Terminal activated — Telegram bot is live"
