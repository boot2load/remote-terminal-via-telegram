#!/bin/bash
# Types a message into any Claude Code Terminal window
# If WINDOW_MATCH is set, matches that specific project; otherwise matches any Claude Code window
# Works even if the window is minimized
# Usage: type-to-terminal.sh "message text"

set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/load-config.sh"

MESSAGE="${1:?Usage: type-to-terminal.sh \"message\"}"
MESSAGE=$(echo "$MESSAGE" | sed 's/\\/\\\\/g; s/"/\\"/g')

if [ -n "$WINDOW_MATCH" ]; then
  osascript - "$WINDOW_MATCH" "$MESSAGE" <<'EOF'
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
  osascript - "$MESSAGE" <<'EOF'
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
