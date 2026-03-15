#!/usr/bin/env bash
# Send a message to Telegram
# Security: uses --data-urlencode for proper encoding, hides token from ps
# Usage: send.sh "Your message here"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

MESSAGE="${1:?Usage: send.sh \"message\"}"

# Hide token from process list
_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage\"" > "$_URL_FILE"
trap 'rm -f "$_URL_FILE"' EXIT

curl -s -K "$_URL_FILE" \
  -d chat_id="${TELEGRAM_CHAT_ID}" \
  --data-urlencode "text=${MESSAGE}" \
  -d parse_mode="Markdown" \
  --fail-with-body
