#!/usr/bin/env bash
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

# Ensure only one instance using flock (cross-platform, race-condition free)
LOCK_FILE="$RTVT_DIR/.poll.lock"
exec 9>"$LOCK_FILE"
if ! flock -n 9 2>/dev/null; then
  # flock not available or lock held — fallback to PID check
  if [ -f "$PID_FILE" ]; then
    OLD_PID=$(cat "$PID_FILE")
    if [[ "$OLD_PID" =~ ^[0-9]+$ ]] && kill -0 "$OLD_PID" 2>/dev/null; then
      echo "Poller already running (PID $OLD_PID), exiting" >> "$LOG_FILE"
      exit 0
    fi
  fi
fi

echo $$ > "$PID_FILE"
chmod 600 "$PID_FILE" 2>/dev/null || true
cleanup_poll() {
  [ "$(cat "$PID_FILE" 2>/dev/null)" = "$$" ] && rm -f "$PID_FILE" "$LOCK_FILE"
  rm -f "$_TG_URL_FILE" 2>/dev/null || true
}
trap cleanup_poll EXIT

# Dangerous command patterns — block these from being typed into terminal
# Defense-in-depth: this blocklist catches obvious destructive commands.
# It cannot prevent all evasion (encoding, aliasing, etc.) — Claude Code's
# own approval system is the primary safety layer.
DANGEROUS_PATTERNS='rm\s+(-[a-zA-Z]*r[a-zA-Z]*f|-[a-zA-Z]*f[a-zA-Z]*r|-rf|--recursive|--force)|rm\s+-r\s|mkfs|dd\s+if=|:\(\)\{|\.\(\)\{|chmod\s+[ugo+]*s|chmod\s+-R\s+777|curl.*\|.*(sh|bash|python|perl|ruby)|wget.*\|.*(sh|bash|python|perl|ruby)|(bash|sh|zsh)\s+<\(|\|\s*(sh|bash|zsh)\b|base64.*\|\s*(sh|bash)|sudo\s|> /dev/sd|shutdown|reboot|init\s+0|halt|/dev/tcp/|nc\s+(-[a-zA-Z]*e|--exec)|find.*-delete|find.*-exec.*rm|shred\s|osascript.*do\s+shell\s+script|defaults\s+write.*LoginHook|>\s*/etc/|python3?\s+-c\s+.*os\.(system|exec|popen)|diskutil\s+(erase|unmount|partition)|launchctl\s+(load|submit)|crontab\s'

# Evasion detection: catches common encoding/obfuscation tricks
EVASION_PATTERNS='\\x[0-9a-fA-F]{2}|\\[0-7]{3}|\$\x27|eval\s|xargs.*rm|perl\s+-e|ruby\s+-e|printf.*\\\\|echo.*\\\\x'

is_dangerous() {
  echo "$1" | grep -qiE "$DANGEROUS_PATTERNS" && return 0
  echo "$1" | grep -qiE "$EVASION_PATTERNS" && return 0
  return 1
}

OS_TYPE="$(uname -s)"

# Cross-platform stat: file size
file_size() {
  if [ "$OS_TYPE" = "Darwin" ]; then
    stat -f%z "$1" 2>/dev/null || echo 0
  else
    stat -c%s "$1" 2>/dev/null || echo 0
  fi
}

# Cross-platform stat: modification time (epoch seconds)
file_mtime() {
  if [ "$OS_TYPE" = "Darwin" ]; then
    stat -f %m "$1" 2>/dev/null || echo 0
  else
    stat -c %Y "$1" 2>/dev/null || echo 0
  fi
}

log() {
  # Log with size-based rotation (max 10MB), restrictive permissions
  local LOG_MAX=10485760
  if [ -f "$LOG_FILE" ] && [ "$(file_size "$LOG_FILE")" -gt "$LOG_MAX" ]; then
    tail -1000 "$LOG_FILE" > "$LOG_FILE.tmp" && mv "$LOG_FILE.tmp" "$LOG_FILE"
  fi
  touch "$LOG_FILE" && chmod 600 "$LOG_FILE" 2>/dev/null || true
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
  if [ "$OS_TYPE" = "Darwin" ]; then
    # macOS: AppleScript Escape key injection
    if [ -n "$WINDOW_MATCH" ]; then
      osascript - "$WINDOW_MATCH" <<'ASEOF' 2>/dev/null || true
on run argv
    set matchStr to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            try
                set wName to name of w
                if wName contains matchStr and wName contains "Claude Code" then
                    if miniaturized of w then set miniaturized of w to false
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
    else
      osascript <<'ASEOF' 2>/dev/null || true
tell application "Terminal"
    repeat with w in windows
        try
            if name of w contains "Claude Code" then
                if miniaturized of w then set miniaturized of w to false
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
ASEOF
    fi
  elif [ "$OS_TYPE" = "Linux" ]; then
    # Linux: tmux send Escape key
    TMUX_SESSION="${TMUX_SESSION:-}"
    local ESC_PANE=""
    if [ -n "$TMUX_SESSION" ]; then
      ESC_PANE=$(tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1)
    else
      # Find Claude pane
      ESC_PANE=$(tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_title}' 2>/dev/null | grep -i claude | head -1 | awk '{print $1}')
      if [ -z "$ESC_PANE" ]; then
        # Fallback: check pane content
        local ALL_P
        ALL_P=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || echo "")
        while IFS= read -r p; do
          [ -z "$p" ] && continue
          if tmux capture-pane -t "$p" -p -S -5 2>/dev/null | grep -qE "Claude Code|⏺"; then
            ESC_PANE="$p"
            break
          fi
        done <<< "$ALL_P"
      fi
    fi
    [ -n "$ESC_PANE" ] && tmux send-keys -t "$ESC_PANE" Escape 2>/dev/null || true
  elif [[ "$OS_TYPE" == MINGW* ]] || [[ "$OS_TYPE" == MSYS* ]] || [[ "$OS_TYPE" == CYGWIN* ]]; then
    # Windows: PowerShell Escape key injection
    local PS_SCRIPT="$SCRIPT_DIR/windows/send-escape.ps1"
    if [ -f "$PS_SCRIPT" ]; then
      local MATCH_ARG=""
      [ -n "$WINDOW_MATCH" ] && MATCH_ARG="-WindowMatch \"$WINDOW_MATCH\""
      powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "$PS_SCRIPT")" $MATCH_ARG 2>/dev/null || true
    fi
  fi
}

# Use a netrc-style file to hide token from ps aux
_TG_URL_FILE=$(mktemp)
chmod 600 "$_TG_URL_FILE"
# $_TG_URL_FILE cleanup handled by cleanup_poll trap

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
            if file_id and re.match(r'^[A-Za-z0-9_-]+$', file_id):
                messages.append(f'__VOICE__{file_id}')
                msg_count += 1

        # Handle documents (PDF, TXT, etc.)
        doc = msg.get('document', {})
        if doc:
            file_id = doc.get('file_id', '')
            file_name = doc.get('file_name', 'document')
            caption = msg.get('caption', '')
            if file_id and re.match(r'^[A-Za-z0-9_-]+$', file_id):
                messages.append(f'__FILE__{file_id}|{file_name}|{caption}')
                msg_count += 1

        # Handle photos (screenshots, images)
        photos = msg.get('photo', [])
        if photos:
            best = photos[-1]
            file_id = best.get('file_id', '')
            caption = msg.get('caption', '')
            if file_id and re.match(r'^[A-Za-z0-9_-]+$', file_id):
                messages.append(f'__PHOTO__{file_id}|{caption}')
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
    clean = re.sub(r'[\x00-\x08\x0b-\x0c\x0e-\x1f\x7f]', '', m)
    clean = clean.replace(chr(13), ' ')
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
        VOICE_AGE=$(( $(date +%s) - $(file_mtime "$RTVT_DIR/.pending_voice.txt") ))
        if [ "$VOICE_AGE" -gt 60 ]; then
          rm -f "$RTVT_DIR/.pending_voice.txt"
          "$SCRIPT_DIR/type-to-terminal.sh" "$MSG" 2>/dev/null || true
        elif [ "$MSG" = "1" ]; then
          VOICE_TEXT=$(cat "$RTVT_DIR/.pending_voice.txt")
          rm -f "$RTVT_DIR/.pending_voice.txt"
          if is_dangerous "$VOICE_TEXT"; then
            log "BLOCKED dangerous voice command (${#VOICE_TEXT} chars)"
            tg_curl "sendMessage" \
              -d chat_id="${TELEGRAM_CHAT_ID}" \
              --data-urlencode "text=🚫 Blocked: dangerous command in voice transcription" \
              > /dev/null 2>&1
          else
            tg_curl "sendMessage" \
              -d chat_id="${TELEGRAM_CHAT_ID}" \
              -d text="✅ Sent to terminal" \
              -d disable_notification=true > /dev/null 2>&1
            "$SCRIPT_DIR/type-to-terminal.sh" "$VOICE_TEXT" 2>/dev/null || true
          fi
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

          _VOICE_TMP=$(mktemp "$RTVT_DIR/.voice_result_XXXXXX")
          chmod 600 "$_VOICE_TMP"
          "$SCRIPT_DIR/transcribe-voice.sh" "$FILE_ID" > "$_VOICE_TMP" 2>/dev/null || true
          TRANSCRIBED=$(cat "$_VOICE_TMP" 2>/dev/null | head -1)
          rm -f "$_VOICE_TMP"

          if [ -n "$TRANSCRIBED" ]; then
            # Write to temp file first, then move (prevents symlink attacks)
            _VOICE_PENDING=$(mktemp "$RTVT_DIR/.pending_voice_XXXXXX")
            chmod 600 "$_VOICE_PENDING"
            echo "$TRANSCRIBED" > "$_VOICE_PENDING"
            mv -f "$_VOICE_PENDING" "$RTVT_DIR/.pending_voice.txt"
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

      elif [[ "$MSG" == __FILE__* ]]; then
        FILE_META="${MSG#__FILE__}"
        FILE_ID=$(echo "$FILE_META" | cut -d'|' -f1)
        # Sanitize filename: strip path components and dangerous characters
        FILE_NAME=$(echo "$FILE_META" | cut -d'|' -f2 | tr -cd 'A-Za-z0-9._- ')
        [ -z "$FILE_NAME" ] && FILE_NAME="document"
        # Sanitize and truncate caption
        CAPTION=$(echo "$FILE_META" | cut -d'|' -f3 | tr -cd 'A-Za-z0-9 .,;:!?()_-' | cut -c1-200)

        tg_curl "sendMessage" \
          -d chat_id="${TELEGRAM_CHAT_ID}" \
          --data-urlencode "text=📎 Downloading ${FILE_NAME}..." \
          -d disable_notification=true > /dev/null 2>&1

        LOCAL_PATH=$("$SCRIPT_DIR/download-file.sh" "$FILE_ID" "$FILE_NAME" 2>/dev/null || echo "")
        if [ -n "$LOCAL_PATH" ] && [ -f "$LOCAL_PATH" ]; then
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=📎 File saved: ${FILE_NAME}" \
            -d disable_notification=true > /dev/null 2>&1
          INSTRUCTION="Please read this file: ${LOCAL_PATH}"
          [ -n "$CAPTION" ] && INSTRUCTION="$INSTRUCTION — ${CAPTION}"
          "$SCRIPT_DIR/type-to-terminal.sh" "$INSTRUCTION" 2>/dev/null || true
        else
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="❌ Failed to download file" > /dev/null 2>&1
        fi

      elif [[ "$MSG" == __PHOTO__* ]]; then
        PHOTO_META="${MSG#__PHOTO__}"
        PHOTO_ID=$(echo "$PHOTO_META" | cut -d'|' -f1)
        # Sanitize and truncate caption
        CAPTION=$(echo "$PHOTO_META" | cut -d'|' -f2 | tr -cd 'A-Za-z0-9 .,;:!?()_-' | cut -c1-200)
        PHOTO_NAME="screenshot_$(date +%Y%m%d_%H%M%S).jpg"

        tg_curl "sendMessage" \
          -d chat_id="${TELEGRAM_CHAT_ID}" \
          -d text="📸 Downloading image..." \
          -d disable_notification=true > /dev/null 2>&1

        LOCAL_PATH=$("$SCRIPT_DIR/download-file.sh" "$PHOTO_ID" "$PHOTO_NAME" 2>/dev/null || echo "")
        if [ -n "$LOCAL_PATH" ] && [ -f "$LOCAL_PATH" ]; then
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            --data-urlencode "text=📸 Image saved: ${PHOTO_NAME}" \
            -d disable_notification=true > /dev/null 2>&1
          INSTRUCTION="Please look at this screenshot: ${LOCAL_PATH}"
          [ -n "$CAPTION" ] && INSTRUCTION="$INSTRUCTION — ${CAPTION}"
          "$SCRIPT_DIR/type-to-terminal.sh" "$INSTRUCTION" 2>/dev/null || true
        else
          tg_curl "sendMessage" \
            -d chat_id="${TELEGRAM_CHAT_ID}" \
            -d text="❌ Failed to download image" > /dev/null 2>&1
        fi

      else
        # Regular text message — check for dangerous commands before typing
        if is_dangerous "$MSG"; then
          log "BLOCKED dangerous command (${#MSG} chars)"
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

    # Write to inbox as backup (errors must not crash the daemon)
    echo "$RESULT" | tail -n +2 | while IFS= read -r MSG; do
      [ -z "$MSG" ] && continue
      [ "$MSG" = "__ESCAPE__" ] && continue
      [ "$MSG" = "__IGNORE__" ] && continue
      mkdir -p "$RTVT_DIR/inbox"
      INBOX_FILE=$(mktemp "$RTVT_DIR/inbox/msg_XXXXXXXXXX.txt" 2>/dev/null) || continue
      chmod 600 "$INBOX_FILE"
      # Strip terminal escape sequences before writing
      _ESC=$(printf '\033')
      printf '%s' "$MSG" | sed "s/${_ESC}\[[0-9;]*[A-Za-z]//g" > "$INBOX_FILE"
    done
  fi

  sleep 1
done
