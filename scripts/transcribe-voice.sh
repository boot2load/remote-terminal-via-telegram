#!/usr/bin/env bash
# Downloads a Telegram voice message and transcribes it
# Supports mlx-whisper (local) and OpenAI Whisper API (cloud)
# Security: validates file_id, uses env vars for API keys, temp in project dir
# Usage: transcribe-voice.sh <file_id>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

FILE_ID="${1:?Usage: transcribe-voice.sh <file_id>}"

# Validate file_id format (alphanumeric, hyphens, underscores only)
if ! echo "$FILE_ID" | grep -qE '^[A-Za-z0-9_-]+$'; then
  echo "ERROR: Invalid file_id format" >&2
  exit 1
fi

# Use project-local temp dir with restricted permissions
TMP_DIR=$(mktemp -d "$RTVT_DIR/.tmp_voice_XXXXXX")
chmod 700 "$TMP_DIR"
trap 'rm -rf "$TMP_DIR"' EXIT

# Hide token from process list
_URL_FILE=$(mktemp)
chmod 600 "$_URL_FILE"
echo "url = \"https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${FILE_ID}\"" > "$_URL_FILE"

FILE_PATH=$(curl -s -K "$_URL_FILE" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['file_path'])")

# Validate file_path
if ! echo "$FILE_PATH" | grep -qE '^[A-Za-z0-9_./-]+$'; then
  echo "ERROR: Invalid file_path format" >&2
  rm -f "$_URL_FILE"
  exit 1
fi

echo "url = \"https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${FILE_PATH}\"" > "$_URL_FILE"
curl -s -K "$_URL_FILE" -o "$TMP_DIR/voice.ogg"
rm -f "$_URL_FILE"

# Convert to wav
ffmpeg -i "$TMP_DIR/voice.ogg" -ar 16000 -ac 1 "$TMP_DIR/voice.wav" -y -loglevel quiet

case "$VOICE_BACKEND" in
  mlx-whisper)
    VENV_PYTHON="$RTVT_DIR/.venv/bin/python3"
    export WAV_PATH="$TMP_DIR/voice.wav"
    export _MLX_MODEL_NAME="$MLX_MODEL"
    "$VENV_PYTHON" -c '
import mlx_whisper, os
result = mlx_whisper.transcribe(os.environ["WAV_PATH"], path_or_hf_repo=os.environ["_MLX_MODEL_NAME"])
text = result.get("text", "").strip()
if text:
    print(text)
' 2>/dev/null
    unset WAV_PATH _MLX_MODEL_NAME
    ;;
  openai)
    # Hide API key from process list using header file
    _HDR_FILE=$(mktemp)
    chmod 600 "$_HDR_FILE"
    echo "header = \"Authorization: Bearer ${OPENAI_API_KEY}\"" > "$_HDR_FILE"
    curl -s -K "$_HDR_FILE" \
      https://api.openai.com/v1/audio/transcriptions \
      -F file="@$TMP_DIR/voice.wav" \
      -F model="whisper-1" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('text','').strip())"
    rm -f "$_HDR_FILE"
    ;;
  *)
    echo ""
    ;;
esac
