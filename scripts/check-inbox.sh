#!/bin/bash
# Check for new Telegram messages in the inbox
# Silent when empty (white dot), purple when messages arrive

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
RTVT_DIR="$SCRIPT_DIR/.."
INBOX="$RTVT_DIR/inbox"

[ -d "$INBOX" ] || exit 0

FOUND=false
for f in "$INBOX"/*.txt; do
  [ -f "$f" ] || continue
  FOUND=true
  MSG=$(cat "$f")
  echo -e "\033[35m📩 Telegram: ${MSG}\033[0m"
  rm "$f"
done

if [ "$FOUND" = false ]; then
  echo -e "\033[37m·\033[0m"
fi
