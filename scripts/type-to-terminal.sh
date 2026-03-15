#!/usr/bin/env bash
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
  # Check Accessibility permissions (System Events requires it for keystrokes)
  if ! osascript -e 'tell application "System Events" to return name of first process' &>/dev/null; then
    echo "ERROR: Terminal.app needs Accessibility permissions." >&2
    echo "  Go to: System Settings > Privacy & Security > Accessibility" >&2
    echo "  Enable Terminal.app (or your terminal emulator)" >&2
    exit 1
  fi
  # Escape backslashes, double quotes, tabs, and newlines for AppleScript
  MESSAGE_ESCAPED=$(printf '%s' "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g' | tr '\t' ' ' | tr '\n' ' ')

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

    # Search all panes for Claude Code (using process substitution to avoid subshell)
    local PANE_LIST
    PANE_LIST=$(tmux list-panes -a -F '#{pane_id} #{pane_current_command} #{pane_title}' 2>/dev/null || echo "")
    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local P_ID REST
      P_ID=$(echo "$line" | awk '{print $1}')
      REST=$(echo "$line" | cut -d' ' -f2-)
      if echo "$REST" | grep -qi "claude"; then
        echo "$P_ID"
        return
      fi
    done <<< "$PANE_LIST"

    # Fallback: check pane content for Claude Code markers
    local ALL_PANES
    ALL_PANES=$(tmux list-panes -a -F '#{pane_id}' 2>/dev/null || echo "")
    while IFS= read -r pane; do
      [ -z "$pane" ] && continue
      local CONTENT
      CONTENT=$(tmux capture-pane -t "$pane" -p -S -20 2>/dev/null || echo "")
      if echo "$CONTENT" | grep -qE "Claude Code|⏺"; then
        echo "$pane"
        return
      fi
    done <<< "$ALL_PANES"
  }

  PANE=$(find_claude_pane)
  if [ -z "$PANE" ]; then
    echo "ERROR: No Claude Code tmux pane found" >&2
    exit 1
  fi

  # Use -l (literal) to prevent tmux from interpreting key names, then send Enter separately
  tmux send-keys -l -t "$PANE" "$MESSAGE"
  tmux send-keys -t "$PANE" Enter
elif [[ "$OS_TYPE" == MINGW* ]] || [[ "$OS_TYPE" == MSYS* ]] || [[ "$OS_TYPE" == CYGWIN* ]]; then
  # ── Windows: PowerShell keystroke injection ──
  PS_SCRIPT="$SCRIPT_DIR/windows/type-to-terminal.ps1"
  if [ ! -f "$PS_SCRIPT" ]; then
    echo "ERROR: Windows PowerShell script not found: $PS_SCRIPT" >&2
    exit 1
  fi
  MATCH_ARG=""
  if [ -n "$WINDOW_MATCH" ]; then
    MATCH_ARG="-WindowMatch \"$WINDOW_MATCH\""
  fi
  powershell.exe -ExecutionPolicy Bypass -File "$(cygpath -w "$PS_SCRIPT")" -Message "$MESSAGE" $MATCH_ARG
else
  echo "ERROR: Unsupported OS: $OS_TYPE. Supported: macOS, Linux (tmux), Windows (Git Bash)" >&2
  exit 1
fi
