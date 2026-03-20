#!/usr/bin/env bash
# Watchdog daemon — monitors poll.sh and terminal-watcher.py, restarts if they die
# Runs as a background process, writes PID to .watchdog.pid
# Stops when .active flag is removed

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

LOG_FILE="$RTVT_DIR/daemon.log"
ACTIVE_FLAG="$RTVT_DIR/.active"
WATCHDOG_PID_FILE="$RTVT_DIR/.watchdog.pid"

# Write our PID
echo $$ > "$WATCHDOG_PID_FILE"
chmod 600 "$WATCHDOG_PID_FILE" 2>/dev/null || true
trap 'rm -f "$WATCHDOG_PID_FILE"' EXIT

# Restart counters (max 5 restarts per daemon)
POLL_RESTARTS=0
WATCHER_RESTARTS=0
MAX_RESTARTS=5

log_watchdog() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') [watchdog] $1" >> "$LOG_FILE"
}

send_telegram_notification() {
  local MSG="$1"
  local _URL_FILE
  _URL_FILE=$(mktemp)
  chmod 600 "$_URL_FILE"
  echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" > "$_URL_FILE"
  curl -s -K "$_URL_FILE" \
    -d chat_id="${TELEGRAM_CHAT_ID}" \
    --data-urlencode "text=${MSG}" \
    > /dev/null 2>&1 || true
  rm -f "$_URL_FILE"
}

is_pid_alive() {
  local PID_FILE="$1"
  if [ ! -f "$PID_FILE" ]; then
    return 1
  fi
  local PID
  PID=$(cat "$PID_FILE" 2>/dev/null || echo "")
  if [[ "$PID" =~ ^[0-9]+$ ]] && [ "$PID" -gt 1 ] && kill -0 "$PID" 2>/dev/null; then
    return 0
  fi
  return 1
}

log_watchdog "Watchdog started (PID $$)"

while [ -f "$ACTIVE_FLAG" ]; do
  sleep 15

  # Re-check active flag after sleep
  [ -f "$ACTIVE_FLAG" ] || break

  # Check poll.sh daemon
  if ! is_pid_alive "$RTVT_DIR/.poll.pid"; then
    if [ "$POLL_RESTARTS" -lt "$MAX_RESTARTS" ]; then
      POLL_RESTARTS=$((POLL_RESTARTS + 1))
      log_watchdog "poll.sh died, restarting (attempt $POLL_RESTARTS/$MAX_RESTARTS)"
      rm -rf "$RTVT_DIR/.poll.lock" "$RTVT_DIR/.poll.flock" "$RTVT_DIR/.poll.pid" 2>/dev/null || true
      nohup "$RTVT_DIR/scripts/poll.sh" >> "$LOG_FILE" 2>&1 &
      send_telegram_notification "⚠️ Daemon restarted (poll) — attempt $POLL_RESTARTS/$MAX_RESTARTS"
    elif [ "$POLL_RESTARTS" -eq "$MAX_RESTARTS" ]; then
      POLL_RESTARTS=$((POLL_RESTARTS + 1))
      log_watchdog "poll.sh exceeded max restarts ($MAX_RESTARTS), giving up"
      send_telegram_notification "🔴 poll.sh exceeded max restarts ($MAX_RESTARTS), giving up"
    fi
  fi

  # Check terminal-watcher.py daemon
  if ! is_pid_alive "$RTVT_DIR/.watcher.pid"; then
    if [ "$WATCHER_RESTARTS" -lt "$MAX_RESTARTS" ]; then
      WATCHER_RESTARTS=$((WATCHER_RESTARTS + 1))
      log_watchdog "terminal-watcher.py died, restarting (attempt $WATCHER_RESTARTS/$MAX_RESTARTS)"
      rm -f "$RTVT_DIR/.watcher.pid" 2>/dev/null || true
      nohup python3 "$RTVT_DIR/scripts/terminal-watcher.py" >> "$LOG_FILE" 2>&1 &
      send_telegram_notification "⚠️ Daemon restarted (watcher) — attempt $WATCHER_RESTARTS/$MAX_RESTARTS"
    elif [ "$WATCHER_RESTARTS" -eq "$MAX_RESTARTS" ]; then
      WATCHER_RESTARTS=$((WATCHER_RESTARTS + 1))
      log_watchdog "terminal-watcher.py exceeded max restarts ($MAX_RESTARTS), giving up"
      send_telegram_notification "🔴 terminal-watcher.py exceeded max restarts ($MAX_RESTARTS), giving up"
    fi
  fi
done

log_watchdog "Watchdog stopped (.active flag removed)"
