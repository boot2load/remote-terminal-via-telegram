#!/bin/bash
# Types a message into any Claude Code Terminal window
# macOS: AppleScript + Terminal.app | Linux: tmux send-keys
# Usage: type-to-terminal.sh "message text"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

MESSAGE="${1:?Usage: type-to-terminal.sh \"message\"}"

OS_TYPE="$(uname -s)"

if [ "$OS_TYPE" = "Darwin" ]; then
  # ── macOS: AppleScript keystroke injection ──
  MESSAGE_ESCAPED=$(echo "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')

  if [ -n "$WINDOW_MATCH" ]; then
    osascript - "$WINDOW_MATCH" "$MESSAGE_ESCAPED" <<'EOF'
on run argv
    set matchStr to item 1 of argv
    set msg to item 2 of argv
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
                    delay 0.5
                    tell application "System Events"
                        tell process "Terminal"
                            keystroke msg
                            keystroke return
                        end tell
                    end tell
                    return
                end if
            end try
        end repeat
    end tell
end run
EOF
  else
    osascript - "$MESSAGE_ESCAPED" <<'EOF'
on run argv
    set msg to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            try
                set wName to name of w
                if wName contains "Claude Code" then
                    if miniaturized of w then
                        set miniaturized of w to false
                        delay 0.5
                    end if
                    set frontmost of w to true
                    activate
                    delay 0.5
                    tell application "System Events"
                        tell process "Terminal"
                            keystroke msg
                            keystroke return
                        end tell
                    end tell
                    return
                end if
            end try
        end repeat
    end tell
end run
EOF
  fi

elif [ "$OS_TYPE" = "Linux" ]; then
  # ── Linux: tmux send-keys ──
  TMUX_SESSION="${TMUX_SESSION:-}"

  find_claude_pane() {
    # If a specific session is configured, use it
    if [ -n "$TMUX_SESSION" ]; then
      tmux list-panes -t "$TMUX_SESSION" -F '#{pane_id}' 2>/dev/null | head -1
      return
    fi

    # Search all panes for Claude Code
    tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_title}' 2>/dev/null | while IFS= read -r line; do
      PANE_ID=$(echo "$line" | awk '{print $1}')
      REST=$(echo "$line" | cut -d' ' -f2-)
      if echo "$REST" | grep -qi "claude"; then
        echo "$PANE_ID"
        return
      fi
    done

    # Fallback: check pane content
    tmux list-panes -a -F '#{pane_id}' 2>/dev/null | while IFS= read -r pane; do
      [ -z "$pane" ] && continue
      CONTENT=$(tmux capture-pane -t "$pane" -p -S -20 2>/dev/null || echo "")
      if echo "$CONTENT" | grep -q "Claude Code\|⏺"; then
        echo "$pane"
        return
      fi
    done
  }

  PANE=$(find_claude_pane)
  if [ -z "$PANE" ]; then
    echo "ERROR: No Claude Code tmux pane found" >&2
    exit 1
  fi

  tmux send-keys -t "$PANE" "$MESSAGE" Enter
else
  echo "ERROR: Unsupported OS: $OS_TYPE" >&2
  exit 1
fi
