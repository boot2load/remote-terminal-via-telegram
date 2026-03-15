#!/bin/bash
# Downloads a Telegram voice message and transcribes it
# Supports mlx-whisper (local) and OpenAI Whisper API (cloud)
# Usage: transcribe-voice.sh <file_id>

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

FILE_ID="${1:?Usage: transcribe-voice.sh <file_id>}"
TMP_DIR=$(mktemp -d)
trap 'rm -rf "$TMP_DIR"' EXIT

# Download voice file from Telegram
FILE_PATH=$(curl -s "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/getFile?file_id=${FILE_ID}" \
  | python3 -c "import sys,json; print(json.load(sys.stdin)['result']['file_path'])")
curl -s "https://api.telegram.org/file/bot${TELEGRAM_BOT_TOKEN}/${FILE_PATH}" -o "$TMP_DIR/voice.ogg"

# Convert to wav
ffmpeg -i "$TMP_DIR/voice.ogg" -ar 16000 -ac 1 "$TMP_DIR/voice.wav" -y -loglevel quiet

case "$VOICE_BACKEND" in
  mlx-whisper)
    VENV_PYTHON="$RTVT_DIR/.venv/bin/python3"
    export WAV_PATH="$TMP_DIR/voice.wav"
    "$VENV_PYTHON" -c "
import mlx_whisper, os
result = mlx_whisper.transcribe(os.environ['WAV_PATH'], path_or_hf_repo='$MLX_MODEL')
text = result.get('text', '').strip()
if text:
    print(text)
" 2>/dev/null
    ;;
  openai)
    curl -s https://api.openai.com/v1/audio/transcriptions \
      -H "Authorization: Bearer $OPENAI_API_KEY" \
      -F file="@$TMP_DIR/voice.wav" \
      -F model="whisper-1" \
      | python3 -c "import sys,json; print(json.load(sys.stdin).get('text','').strip())"
    ;;
  *)
    echo ""
    ;;
esac
