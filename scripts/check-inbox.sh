#!/usr/bin/env bash
# Check for new Telegram messages in the inbox
# Silent when empty (white dot), purple when messages arrive
# Security: uses printf instead of echo -e, strips control chars

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTVT_DIR="$SCRIPT_DIR/.."
INBOX="$RTVT_DIR/inbox"

[ -d "$INBOX" ] || exit 0

FOUND=false
for f in "$INBOX"/*.txt; do
  [ -f "$f" ] || continue
  FOUND=true
  # Strip terminal escape sequences for safety
  MSG=$(cat "$f" | sed 's/\x1b\[[0-9;]*[A-Za-z]//g')
  printf '\033[35m📩 Telegram: %s\033[0m\n' "$MSG"
  rm "$f"
done

if [ "$FOUND" = false ]; then
  printf '\033[37m·\033[0m\n'
fi
