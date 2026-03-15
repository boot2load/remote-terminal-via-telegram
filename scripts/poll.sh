#!/bin/bash
# Polls Telegram for incoming messages and types them into the Claude Code terminal
# Security: sender authentication, command blocklist, rate limiting, input validation
# Runs as a background daemon while Remote Terminal is active

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

OFFSET_FILE="$RTVT_DIR/.last_update_id"
ACTIVE_FLAG="$RTVT_DIR/.active"
PID_FILE="$RTVT_DIR/.poll.pid"
LOG_FILE="$RTVT_DIR/daemon.log"
MAX_MSG_PER_CYCLE=5
MAX_MSG_LENGTH=500

# Ensure only one instance — use lock directory (atomic on all filesystems)
LOCK_DIR="$RTVT_DIR/.poll.lock"
if ! mkdir "$LOCK_DIR" 2>/dev/null; then
  # Check if the lock holder is still alive
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Poller already running (PID $OLD_PID), exiting" >> "$LOG_FILE"
      exit 0
    fi
  fi
  rm -rf "$LOCK_DIR"
  mkdir "$LOCK_DIR" 2>/dev/null || exit 1
fi
echo $$ > "$PID_FILE"
trap 'rm -rf "$LOCK_DIR" "$PID_FILE"' EXIT

# Dangerous command patterns — block these from being typed into terminal
DANGEROUS_PATTERNS='rm -rf|mkfs|dd if=|:(){ :|chmod -R 777|curl.*\|.*sh|wget.*\|.*sh|sudo rm|> /dev/sd|shutdown|reboot|init 0|halt'

is_dangerous() {
  echo "$1" | grep -qiE "$DANGEROUS_PATTERNS"
}

log() {
  echo "$(date '+%Y-%m-%d %H:%M:%S') $1" >> "$LOG_FILE"
}

OFFSET=0
if [ -f "$OFFSET_FILE" ]; then
  # Validate offset is a positive integer
  STORED=$(cat "$OFFSET_FILE")
  if [[ "$STORED" =~ ^[0-9]+$ ]]; then
    OFFSET="$STORED"
  fi
fi

send_escape() {
  osascript - "$WINDOW_MATCH" <<'ASEOF' 2>/dev/null || true
on run argv
    set matchStr to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            try
                set wName to name of w
                if wName contains matchStr and wName contains "Claude Code" then
                    if miniaturized of w then
                        set miniaturized of w to false
                        delay 0.5
                    end if
                    set frontmost of w to true
                    activate
                    delay 0.3
                    tell application "System Events"
                        tell process "Terminal"
                            key code 53
                        end tell
                    end tell
                    return
                end if
            end try
        end repeat
    end tell
end run
ASEOF
}

# Use a netrc-style file to hide token from ps aux
_TG_URL_FILE=$(mktemp)
chmod 600 "$_TG_URL_FILE"
trap 'rm -rf "$LOCK_DIR" "$PID_FILE" "$_TG_URL_FILE"' EXIT

tg_curl() {
  # Wrapper that hides bot token from process list
  local ENDPOINT="$1"
  shift
  echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/${ENDPOINT}\"" > "$_TG_URL_FILE"
  curl -s -K "$_TG_URL_FILE" "$@"
}

while [ -f "$ACTIVE_FLAG" ]; do
  RESPONSE=$(tg_curl "getUpdates?offset=${OFFSET}&timeout=5" 2>/dev/null || echo '{"ok":false}')

  RESULT=$(echo "$RESPONSE" | python3 -c "
import sys, json, os, re

data = json.load(sys.stdin)
if not data.get('ok', False):
    sys.exit(0)

results = data.get('result', [])
chat_id = int(os.environ.get('TELEGRAM_CHAT_ID', 0))
allowed_user_id = int(os.environ.get('ALLOWED_USER_ID', chat_id))
max_id = 0
messages = []
msg_count = 0
max_per_cycle = int(os.environ.get('MAX_MSG_PER_CYCLE', 5))

button_map = {
    '✅ 1. Yes': '1',
    '✅ 2. Always': '2',
    '❌ 3. No': '3',
    '🛑 Esc (cancel)': '__ESCAPE__',
    '📋 Status': 'what is the current status of the work?',
    '🔄 Continue': 'please continue with the next task',
    '↩️ Undo last change': 'please undo the last change you made',
    '⏹ /terminal-control-end': '/terminal-control-end',
    '⬜ Not connected to terminal': '__IGNORE__',
    '▶️ /terminal-control-start': '__IGNORE__',
}

for update in results:
    uid = update.get('update_id', 0)
    if uid > max_id:
        max_id = uid

    # Rate limit: max messages per cycle
    if msg_count >= max_per_cycle:
        continue

    msg = update.get('message', {})
    # Authenticate sender: check both chat_id AND from.id
    sender_id = msg.get('from', {}).get('id', 0)
    if msg.get('chat', {}).get('id') == chat_id and sender_id == allowed_user_id:
        text = msg.get('text', '').strip()
        if text:
            mapped = button_map.get(text, text)
            messages.append(mapped)
            msg_count += 1

        voice = msg.get('voice', {})
        if voice:
            file_id = voice.get('file_id', '')
            # Validate file_id format
            if file_id and re.match(r'^[A-Za-z0-9_-]+$', file_id):
                messages.append(f'__VOICE__{file_id}')
                msg_count += 1

    cb = update.get('callback_query', {})
    if cb:
        cb_chat = cb.get('message', {}).get('chat', {}).get('id')
        cb_sender = cb.get('from', {}).get('id', 0)
        if cb_chat == chat_id and cb_sender == allowed_user_id:
            action = cb.get('data', '')
            if action == 'approve':
                messages.append('y')
            elif action in ('reject', 'deny'):
                messages.append('n')

if max_id > 0:
    print(max_id + 1)
else:
    print(0)
for m in messages:
    # Strip control characters
    clean = re.sub(r'[\x00-\x08\x0e-\x1f\x7f]', '', m)
    print(clean.replace(chr(10), ' '))
" 2>/dev/null) || continue

  NEW_OFFSET=$(echo "$RESULT" | head -1)
  if [ "$NEW_OFFSET" != "0" ] && [ -n "$NEW_OFFSET" ]; then
    echo "$NEW_OFFSET" > "$OFFSET_FILE"
    OFFSET="$NEW_OFFSET"

    echo "$RESULT" | tail -n +2 | while IFS= read -r MSG; do
      [ -z "$MSG" ] && continue

      # Truncate long messages
      MSG="${MSG:0:$MAX_MSG_LENGTH}"

      if [ "$MSG" = "__ESCAPE__" ]; then
        send_escape
      elif [ "$MSG" = "__IGNORE__" ]; then
        continue
      elif [ -f "$RTVT_DIR/.pending_voice.txt" ] && { [ "$MSG" = "1" ] || [ "$MSG" = "3" ]; }; then
        VOICE_AGE=$(( $(date +%s) - $(stat -f %m "$RTVT_DIR/.pending_voice.txt" 2>/dev/null || echo 0) ))
        if [ "$VOICE_AGE" -gt 60 ]; then
          rm -f "$RTVT_DIR/.pending_voice.txt"
          "$SCRIPT_DIR/type-to-terminal.sh" "$MSG" 2>/dev/null || true
        elif [ "$MSG" = "1" ]; then
          VOICE_TEXT=$(cat "$RTVT_DIR/.pending_voice.txt")
          rm -f "$RTVT_DIR/.pending_voice.txt"
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="✅ Sent to terminal" \
            -d disable_notification=true > /dev/null 2>&1
          "$SCRIPT_DIR/type-to-terminal.sh" "$VOICE_TEXT" 2>/dev/null || true
        else
          rm -f "$RTVT_DIR/.pending_voice.txt"
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="❌ Voice message cancelled" \
            -d disable_notification=true > /dev/null 2>&1
        fi
      elif [[ "$MSG" == __VOICE__* ]]; then
        FILE_ID="${MSG#__VOICE__}"
        if [ "$VOICE_BACKEND" = "none" ]; then
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="❌ Voice input is not configured. Run setup.sh to enable." \
            > /dev/null 2>&1
        else
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="🎙 Transcribing..." \
            -d disable_notification=true > /dev/null 2>&1

          "$SCRIPT_DIR/transcribe-voice.sh" "$FILE_ID" > "$RTVT_DIR/.voice_result.txt" 2>/dev/null || true
          TRANSCRIBED=$(cat "$RTVT_DIR/.voice_result.txt" 2>/dev/null | head -1)
          rm -f "$RTVT_DIR/.voice_result.txt"

          if [ -n "$TRANSCRIBED" ]; then
            echo "$TRANSCRIBED" > "$RTVT_DIR/.pending_voice.txt"
            chmod 600 "$RTVT_DIR/.pending_voice.txt"
            tg_curl "sendMessage" \
              --data-urlencode "text=🎙 Voice transcription:

${TRANSCRIBED}

Press ✅ 1. Yes to send
Press ❌ 3. No to cancel" \
              -d chat_id="${TELEGRAM_CHAT_ID}" \
              > /dev/null 2>&1
          else
            tg_curl "sendMessage" \
              -d chat_id="${TELEGRAM_CHAT_ID}" \
              -d text="❌ Could not transcribe voice message" \
              > /dev/null 2>&1
          fi
        fi
      else
        # Check for dangerous commands before typing
        if is_dangerous "$MSG"; then
          log "BLOCKED dangerous command: $MSG"
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=🚫 Blocked: potentially dangerous command detected" \
            > /dev/null 2>&1
        else
          "$SCRIPT_DIR/type-to-terminal.sh" "$MSG" 2>/dev/null || true
        fi
      fi
      sleep 1
    done

    # Write to inbox as backup
    echo "$RESULT" | tail -n +2 | while IFS= read -r MSG; do
      [ -z "$MSG" ] && continue
      [ "$MSG" = "__ESCAPE__" ] && continue
      [ "$MSG" = "__IGNORE__" ] && continue
      TS=$(date +%s)
      mkdir -p "$RTVT_DIR/inbox"
      # Use mktemp for unpredictable filenames
      INBOX_FILE=$(mktemp "$RTVT_DIR/inbox/msg_XXXXXX.txt")
      chmod 600 "$INBOX_FILE"
      # Strip terminal escape sequences before writing
      printf '%s' "$MSG" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g' > "$INBOX_FILE"
    done
  fi

  sleep 3
done
