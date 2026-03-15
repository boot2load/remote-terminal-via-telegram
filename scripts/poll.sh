#!/bin/bash
# Polls Telegram for incoming messages and types them into the Claude Code terminal
# Handles regular messages, button presses, voice messages, and special actions
# Runs as a background daemon while Remote Terminal is active

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

OFFSET_FILE="$RTVT_DIR/.last_update_id"
ACTIVE_FLAG="$RTVT_DIR/.active"
PID_FILE="$RTVT_DIR/.poll.pid"

# Ensure only one instance runs
if [ -f "$PID_FILE" ]; then
  OLD_PID=$(cat "$PID_FILE")
  if [ "$OLD_PID" != "$$" ] && kill -0 "$OLD_PID" 2>/dev/null; then
    kill "$OLD_PID" 2>/dev/null
    sleep 0.5
  fi
fi
echo $$ > "$PID_FILE"
trap 'rm -f "$PID_FILE"' EXIT

OFFSET=0
if [ -f "$OFFSET_FILE" ]; then
  OFFSET=$(cat "$OFFSET_FILE")
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

while [ -f "$ACTIVE_FLAG" ]; do
  RESPONSE=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates?offset=${OFFSET}&timeout=5" 2>/dev/null || echo '{"ok":false}')

  RESULT=$(echo "$RESPONSE" | python3 -c "
import sys, json

data = json.load(sys.stdin)
if not data.get('ok', False):
    sys.exit(0)

results = data.get('result', [])
chat_id = $TELEGRAM_CHAT_ID
max_id = 0
messages = []

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

    msg = update.get('message', {})
    if msg.get('chat', {}).get('id') == chat_id:
        text = msg.get('text', '').strip()
        if text:
            mapped = button_map.get(text, text)
            messages.append(mapped)

        voice = msg.get('voice', {})
        if voice:
            file_id = voice.get('file_id', '')
            if file_id:
                messages.append(f'__VOICE__{file_id}')

    cb = update.get('callback_query', {})
    if cb:
        cb_chat = cb.get('message', {}).get('chat', {}).get('id')
        if cb_chat == chat_id:
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
    print(m.replace(chr(10), ' '))
" 2>/dev/null) || continue

  NEW_OFFSET=$(echo "$RESULT" | head -1)
  if [ "$NEW_OFFSET" != "0" ] && [ -n "$NEW_OFFSET" ]; then
    echo "$NEW_OFFSET" > "$OFFSET_FILE"
    OFFSET="$NEW_OFFSET"

    echo "$RESULT" | tail -n +2 | while IFS= read -r MSG; do
      [ -z "$MSG" ] && continue
      if [ "$MSG" = "__ESCAPE__" ]; then
        send_escape
      elif [ "$MSG" = "__IGNORE__" ]; then
        continue
      elif [ -f "$RTVT_DIR/.pending_voice.txt" ] && { [ "$MSG" = "1" ] || [ "$MSG" = "3" ]; }; then
        VOICE_AGE=$(( $(date +%s) - $(stat -f %m "$RTVT_DIR/.pending_voice.txt" 2>/dev/null || echo 0) ))
        if [ "$VOICE_AGE" -gt 60 ]; then
          rm -f "$RTVT_DIR/.pending_voice.txt"
          for attempt in 1 2 3; do
            "$SCRIPT_DIR/type-to-terminal.sh" "$MSG" 2>/dev/null && break
            sleep 1
          done
        elif [ "$MSG" = "1" ]; then
          VOICE_TEXT=$(cat "$RTVT_DIR/.pending_voice.txt")
          rm -f "$RTVT_DIR/.pending_voice.txt"
          curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="✅ Sent to terminal" \
            -d disable_notification=true > /dev/null 2>&1
          for attempt in 1 2 3; do
            "$SCRIPT_DIR/type-to-terminal.sh" "$VOICE_TEXT" 2>/dev/null && break
            sleep 1
          done
        else
          rm -f "$RTVT_DIR/.pending_voice.txt"
          curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="❌ Voice message cancelled" \
            -d disable_notification=true > /dev/null 2>&1
        fi
      elif [[ "$MSG" == __VOICE__* ]]; then
        FILE_ID="${MSG#__VOICE__}"
        if [ "$VOICE_BACKEND" = "none" ]; then
          curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="❌ Voice input is not configured. Run setup.sh to enable." \
            > /dev/null 2>&1
        else
          curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="🎙 Transcribing..." \
            -d disable_notification=true > /dev/null 2>&1

          "$SCRIPT_DIR/transcribe-voice.sh" "$FILE_ID" > "$RTVT_DIR/.voice_result.txt" 2>/dev/null || true
          TRANSCRIBED=$(cat "$RTVT_DIR/.voice_result.txt" 2>/dev/null | head -1)
          rm -f "$RTVT_DIR/.voice_result.txt"

          if [ -n "$TRANSCRIBED" ]; then
            echo "$TRANSCRIBED" > "$RTVT_DIR/.pending_voice.txt"
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
              --data-urlencode "text=🎙 Voice transcription:

${TRANSCRIBED}

Press ✅ 1. Yes to send
Press ❌ 3. No to cancel" \
              -d chat_id="${TELEGRAM_CHAT_ID}" \
              > /dev/null 2>&1
          else
            curl -s -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
              -d chat_id="${TELEGRAM_CHAT_ID}" \
              -d text="❌ Could not transcribe voice message" \
              > /dev/null 2>&1
          fi
        fi
      else
        for attempt in 1 2 3; do
          "$SCRIPT_DIR/type-to-terminal.sh" "$MSG" 2>/dev/null && break
          sleep 1
        done
      fi
      sleep 1
    done

    echo "$RESULT" | tail -n +2 | while IFS= read -r MSG; do
      [ -z "$MSG" ] && continue
      [ "$MSG" = "__ESCAPE__" ] && continue
      TS=$(date +%s)
      mkdir -p "$RTVT_DIR/inbox"
      echo "$MSG" > "$RTVT_DIR/inbox/${TS}_backup.txt"
    done
  fi

  sleep 3
done

rm -f "$PID_FILE"
