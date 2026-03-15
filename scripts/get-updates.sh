#!/bin/bash
# Fetch recent messages sent to the bot
# Security: hides token from process list
# Usage: get-updates.sh

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getUpdates\"" > "$_URL_FILE"
trap 'rm -f "$_URL_FILE"' EXIT

curl -s -K "$_URL_FILE" | python3 -m json.tool
