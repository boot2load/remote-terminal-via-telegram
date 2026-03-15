#!/bin/bash
# Downloads a file from Telegram and saves it locally
# Security: validates file_id, hides token from ps
# Usage: download-file.sh <file_id> <filename>
# Returns: the local file path on stdout

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

FILE_ID="${1:?Usage: download-file.sh <file_id> <filename>}"
FILENAME="${2:-attachment}"

# Validate file_id
if ! echo "$FILE_ID" | grep -qE '^[A-Za-z0-9_-]+$'; then
  echo "ERROR: Invalid file_id" >&2
  exit 1
fi

ATTACH_DIR="$RTVT_DIR/attachments"
mkdir -p "$ATTACH_DIR"
chmod 700 "$ATTACH_DIR"

_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
trap 'rm -f "$_URL_FILE"' EXIT

echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${FILE_ID}\"" > "$_URL_FILE"
FILE_PATH=$(curl -s -K "$_URL_FILE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['file_path'])")

if ! echo "$FILE_PATH" | grep -qE '^[A-Za-z0-9_./-]+$'; then
  echo "ERROR: Invalid file_path" >&2
  exit 1
fi

echo "url = \"https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${FILE_PATH}\"" > "$_URL_FILE"
OUTPUT="$ATTACH_DIR/$FILENAME"
curl -s -K "$_URL_FILE" -o "$OUTPUT"
chmod 600 "$OUTPUT"

echo "$OUTPUT"
