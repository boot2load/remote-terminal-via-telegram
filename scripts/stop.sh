#!/usr/bin/env bash
# Stop Remote Terminal — deactivates Telegram sync
# Security: PID-based cleanup, token hidden from ps
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

LOG_FILE="$RTVT_DIR/daemon.log"

# Calculate session duration
DURATION=""
if [ -f "$RTVT_DIR/.session_start" ]; then
  START_TIME=$(cat "$RTVT_DIR/.session_start")
  if [[ "$START_TIME" =~ ^[0-9]+$ ]]; then
    ELAPSED=$(( $(date +%s) - START_TIME ))
    HOURS=$((ELAPSED / 3600))
    MINUTES=$(( (ELAPSED % 3600) / 60 ))
    if [ $HOURS -gt 0 ]; then
      DURATION="${HOURS}h ${MINUTES}m"
    else
      DURATION="${MINUTES}m"
    fi
  fi
  rm -f "$RTVT_DIR/.session_start"
fi

# Send shutdown message (hide token, safe JSON via python3)
_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" > "$_URL_FILE"
_MSG_JSON=$(DURATION="$DURATION" python3 -c "
import json, os
name = os.environ.get('PROJECT_NAME', 'Terminal')
for ch in ['_', '*', '[', '\`']:
    name = name.replace(ch, '\\\\' + ch)
duration = os.environ.get('DURATION', '')
duration_line = f'\nSession duration: {duration}' if duration else ''
print(json.dumps({
    'chat_id': os.environ['TELEGRAM_CHAT_ID'],
    'text': f'🔴 *Remote Terminal Deactivated*\n{name} session monitoring stopped.{duration_line}\nRun /terminal-control-start to reconnect.',
    'parse_mode': 'Markdown',
    'reply_markup': {
        'keyboard': [
            [{'text': '⬜ Not connected to terminal'}],
            [{'text': '▶️ /terminal-control-start'}]
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

# Deactivate
rm -f "$RTVT_DIR/.active"

# Kill daemons via PID files (including watchdog)
for pidfile in "$RTVT_DIR/.poll.pid" "$RTVT_DIR/.watcher.pid" "$RTVT_DIR/.watchdog.pid"; do
  if [ -f "$pidfile" ]; then
    OLD_PID=$(cat "$pidfile")
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && [ "$OLD_PID" -gt 1 ]; then
      kill "$OLD_PID" 2>/dev/null || true
      sleep 0.5
      kill -9 "$OLD_PID" 2>/dev/null || true
    fi
    rm -f "$pidfile"
  fi
done
rm -f "$RTVT_DIR/.poll.lock" 2>/dev/null || true
rm -f "$RTVT_DIR/.poll.flock" 2>/dev/null || true
rm -f "$RTVT_DIR/.session_start" 2>/dev/null || true
rm -f "$RTVT_DIR/.last_heartbeat" 2>/dev/null || true
rm -f "$RTVT_DIR/.runtime.env" 2>/dev/null || true
rm -f "$RTVT_DIR/inbox"/*.txt 2>/dev/null || true

echo "$(date '+%Y-%m-%d %H:%M:%S') Session stopped" >> "$LOG_FILE"
echo "🔴 Remote Terminal deactivated"
