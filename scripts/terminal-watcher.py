#!/usr/bin/env python3
"""
Claude Code Telegram Agent — Terminal Watcher

Watches a Claude Code terminal session and mirrors output to Telegram
as self-editing messages with clean conversation formatting.

Reads config from config.json for project name, window matching, and Telegram credentials.
"""

import json, os, platform, re, subprocess, sys, tempfile, time, urllib.request, urllib.parse

RTVT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACTIVE_FLAG = os.path.join(RTVT_DIR, ".active")
PID_FILE = os.path.join(RTVT_DIR, ".watcher.pid")
CONFIG_FILE = os.path.join(RTVT_DIR, "config.json")
IS_MACOS = platform.system() == "Darwin"
IS_LINUX = platform.system() == "Linux"
IS_WINDOWS = platform.system() == "Windows" or "MINGW" in platform.platform() or "MSYS" in platform.platform()

with open(CONFIG_FILE) as f:
    config = json.load(f)


def get_from_keychain(account):
    """Retrieve a secret from macOS Keychain (macOS only)."""
    if not IS_MACOS:
        return None
    try:
        result = subprocess.run(
            ["security", "find-generic-password", "-s", "remote-terminal-telegram", "-a", account, "-w"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0:
            return result.stdout.strip()
    except Exception:
        pass
    return None


def get_from_secret_tool(account):
    """Retrieve a secret from GNOME Keyring / libsecret (Linux only)."""
    if not IS_LINUX:
        return None
    try:
        result = subprocess.run(
            ["secret-tool", "lookup", "service", "remote-terminal-telegram", "account", account],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode == 0 and result.stdout.strip():
            return result.stdout.strip()
    except Exception:
        pass
    return None


use_keychain = config.get("security", {}).get("use_keychain", False) and IS_MACOS
use_secret_tool = config.get("security", {}).get("use_secret_tool", False) and IS_LINUX
BOT_TOKEN = ""
if use_keychain:
    BOT_TOKEN = get_from_keychain("bot_token") or ""
elif use_secret_tool:
    BOT_TOKEN = get_from_secret_tool("bot_token") or ""
if not BOT_TOKEN or BOT_TOKEN in ("STORED_IN_KEYCHAIN", "STORED_IN_SECRET_TOOL"):
    BOT_TOKEN = config["telegram"].get("bot_token", "")
if not BOT_TOKEN or BOT_TOKEN in ("STORED_IN_KEYCHAIN", "STORED_IN_SECRET_TOOL"):
    store = "Keychain" if IS_MACOS else "secret-tool"
    print(f"ERROR: Bot token not found in {store} or config.json", file=sys.stderr)
    sys.exit(1)

CHAT_ID = str(config["telegram"]["chat_id"])

# Runtime overrides from .runtime.env take precedence over config.json.
# This allows start.sh to auto-detect the calling terminal session.
RUNTIME_ENV = os.path.join(RTVT_DIR, ".runtime.env")
_runtime = {}
if os.path.exists(RUNTIME_ENV):
    with open(RUNTIME_ENV) as _rf:
        for _line in _rf:
            _line = _line.strip()
            if not _line or _line.startswith("#"):
                continue
            if "=" in _line:
                _k, _v = _line.split("=", 1)
                _k = _k.strip()
                # Remove shell quoting (single quotes from printf %q or $'...' syntax)
                _v = _v.strip().strip("'").strip('"')
                if _v:
                    _runtime[_k] = _v

PROJECT_NAME = _runtime.get("PROJECT_NAME") or config.get("project", {}).get("name", "Terminal")
WINDOW_MATCH = _runtime.get("WINDOW_MATCH") or config.get("project", {}).get("window_match_string", "")
TMUX_SESSION = _runtime.get("TMUX_SESSION") or config.get("project", {}).get("tmux_session", "")
MAX_MSG_LEN = 3900
TELEGRAM_MAX_LEN = 4096
IDLE_TIMEOUT = config.get("idle_timeout_seconds", 300)
HEARTBEAT_FILE = os.path.join(RTVT_DIR, ".last_heartbeat")

with open(PID_FILE, "w") as f:
    f.write(str(os.getpid()))
os.chmod(PID_FILE, 0o600)

# ── macOS: AppleScript for Terminal.app ──
APPLESCRIPT_WITH_MATCH = '''
on run argv
    set matchStr to item 1 of argv
    tell application "Terminal"
        repeat with w in windows
            try
                set wName to name of w
                if wName contains matchStr and wName contains "Claude Code" then
                    return contents of tab 1 of w
                end if
            end try
        end repeat
        return ""
    end tell
end run
'''

APPLESCRIPT_ANY = '''
tell application "Terminal"
    repeat with w in windows
        try
            set wName to name of w
            if wName contains "Claude Code" then
                return contents of tab 1 of w
            end if
        end try
    end repeat
    return ""
end tell
'''


def _find_tmux_pane():
    """Find the tmux pane running Claude Code."""
    try:
        # If a specific session is configured, use it
        if TMUX_SESSION:
            result = subprocess.run(
                ["tmux", "list-panes", "-t", TMUX_SESSION, "-F", "#{pane_id}"],
                capture_output=True, text=True, timeout=5
            )
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.strip().split("\n")[0]

        # Otherwise, search all panes for one running Claude Code
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id} #{pane_current_command} #{pane_title}"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return None
        for line in result.stdout.strip().split("\n"):
            parts = line.split(" ", 2)
            if len(parts) >= 2:
                pane_id = parts[0]
                rest = " ".join(parts[1:]).lower()
                if "claude" in rest:
                    return pane_id

        # Fallback: check pane content for Claude Code markers
        result = subprocess.run(
            ["tmux", "list-panes", "-a", "-F", "#{pane_id}"],
            capture_output=True, text=True, timeout=5
        )
        if result.returncode != 0:
            return None
        for pane_id in result.stdout.strip().split("\n"):
            pane_id = pane_id.strip()
            if not pane_id:
                continue
            content = subprocess.run(
                ["tmux", "capture-pane", "-t", pane_id, "-p", "-S", "-50"],
                capture_output=True, text=True, timeout=5
            )
            if content.returncode == 0 and ("Claude Code" in content.stdout or "⏺" in content.stdout):
                return pane_id
    except Exception:
        pass
    return None

# Secret redaction patterns — masks sensitive data before sending to Telegram
SECRET_PATTERNS = [
    (re.compile(r'(sk-[a-zA-Z0-9]{20,})'), r'sk-***REDACTED***'),
    (re.compile(r'(ghp_[a-zA-Z0-9]{20,})'), r'ghp_***REDACTED***'),
    (re.compile(r'(gho_[a-zA-Z0-9]{20,})'), r'gho_***REDACTED***'),
    (re.compile(r'(AKIA[A-Z0-9]{12,})'), r'AKIA***REDACTED***'),
    (re.compile(r'([a-zA-Z_]*(?:PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY)\s*[=:]\s*)\S+', re.IGNORECASE), r'\1***REDACTED***'),
    (re.compile(r'(Bearer\s+)[a-zA-Z0-9._\-]+'), r'\1***REDACTED***'),
    (re.compile(r'(\d{8,12}:[A-Za-z0-9_-]{30,})'), r'***BOT_TOKEN_REDACTED***'),
    (re.compile(r'-----BEGIN [A-Z ]*(PRIVATE KEY|DSA|RSA|EC).*?-----'), r'***PRIVATE_KEY_REDACTED***'),
    (re.compile(r'eyJ[A-Za-z0-9_-]{10,}\.eyJ[A-Za-z0-9_-]{10,}'), r'***JWT_REDACTED***'),
    (re.compile(r'(postgres|mysql|mongodb|redis|amqp)://[^\s]+'), r'***DB_URI_REDACTED***'),
]


def redact_secrets(text):
    """Remove sensitive patterns from text before sending to Telegram."""
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


SEP_RE = re.compile(r'^[─━═╌┈┄\-]{10,}$')
TABLE_BORDER_RE = re.compile(r'^[┌┬┐├┼┤└┴┘─│╌┈]+$')
TABLE_ROW_RE = re.compile(r'^\s*│(.+)│\s*$')
TRUNCATED_RE = re.compile(r'[…⋯]\s*\+?\s*(\d+)\s*lines?\s*\(ctrl\+o', re.IGNORECASE)


def get_terminal_content():
    try:
        if IS_MACOS:
            # macOS: AppleScript reads Terminal.app window contents
            if WINDOW_MATCH:
                result = subprocess.run(
                    ["osascript", "-e", APPLESCRIPT_WITH_MATCH, "--", WINDOW_MATCH],
                    capture_output=True, text=True, timeout=5
                )
            else:
                result = subprocess.run(
                    ["osascript", "-e", APPLESCRIPT_ANY],
                    capture_output=True, text=True, timeout=5
                )
            return result.stdout
        elif IS_LINUX:
            # Linux: tmux capture-pane reads terminal contents
            pane_id = _find_tmux_pane()
            if not pane_id:
                return ""
            result = subprocess.run(
                ["tmux", "capture-pane", "-t", pane_id, "-p", "-S", "-200"],
                capture_output=True, text=True, timeout=5
            )
            return result.stdout if result.returncode == 0 else ""
        elif IS_WINDOWS:
            # Windows: PowerShell script reads terminal window content
            ps_script = os.path.join(RTVT_DIR, "scripts", "windows", "read-terminal.ps1")
            cmd = ["powershell.exe", "-ExecutionPolicy", "Bypass", "-File", ps_script]
            if WINDOW_MATCH:
                cmd += ["-WindowMatch", WINDOW_MATCH]
            result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
            return result.stdout if result.returncode == 0 else ""
        else:
            return ""
    except Exception:
        return ""


def parse_table(lines):
    rows = []
    for line in lines:
        m = TABLE_ROW_RE.match(line)
        if m:
            cells = [c.strip() for c in m.group(1).split("│")]
            if cells and any(c for c in cells):
                rows.append(cells)
    if not rows:
        return ""
    headers = rows[0]
    data_rows = rows[1:]
    if not data_rows:
        return " | ".join(headers)
    cards = []
    for row in data_rows:
        card_lines = []
        for i, cell in enumerate(row):
            if not cell:
                continue
            if i < len(headers) and headers[i]:
                if headers[i].strip() == "#":
                    card_lines.insert(0, f"#{cell}")
                else:
                    card_lines.append(f"  {headers[i]}: {cell}")
            else:
                card_lines.append(f"  {cell}")
        if card_lines:
            first = card_lines[0]
            if first.startswith("#"):
                cards.append(f"▪️ {first}\n" + "\n".join(card_lines[1:]))
            else:
                cards.append("\n".join(card_lines))
    return "\n\n".join(cards)


def preprocess_tables(raw):
    lines = raw.split("\n")
    result = []
    table_buffer = []
    in_table = False
    for line in lines:
        stripped = line.strip()
        is_table_line = (
            TABLE_BORDER_RE.match(stripped)
            or TABLE_ROW_RE.match(line)
            or (stripped.startswith("│") and stripped.endswith("│"))
            or (stripped.startswith("┌") or stripped.startswith("├") or stripped.startswith("└"))
        )
        if is_table_line:
            in_table = True
            table_buffer.append(line)
        else:
            if in_table and table_buffer:
                converted = parse_table(table_buffer)
                if converted:
                    result.append(converted)
                table_buffer = []
                in_table = False
            result.append(line)
    if table_buffer:
        converted = parse_table(table_buffer)
        if converted:
            result.append(converted)
    return "\n".join(result)


def parse_terminal(raw):
    lines = raw.split("\n")
    turns = []
    current_turn = None
    skip_patterns = (
        "Esc to cancel", "ctrl+", "Tab to amend",
        "This command requires approval", "Command contains",
        "accept edits", "PR #",
        "⏵", "shift+tab to cycle", "esc to interrupt",
        "auto-approve", "· esc",
    )
    has_markers = any("⏺" in l for l in lines)
    is_modal = not has_markers and any("Do you want to" in l for l in lines)

    if is_modal:
        action_line = None
        file_line = None
        code_lines = []
        in_code = False
        for line in lines:
            stripped = line.strip()
            if not stripped or SEP_RE.match(stripped):
                continue
            if re.match(r'^[╌]+$', stripped):
                in_code = not in_code
                continue
            if any(stripped.startswith(p) for p in skip_patterns):
                continue
            if stripped.startswith("Esc to cancel"):
                continue
            if stripped in ("Create file", "Edit file", "Bash command", "Write file", "Read file"):
                action_line = stripped
                continue
            if action_line and not file_line and not stripped.startswith("❯") and "Do you want" not in stripped:
                if not re.match(r'^\d+\s', stripped):
                    file_line = stripped
                    continue
            if in_code or re.match(r'^\s*\d+\s', stripped):
                code_lines.append(stripped)
                continue
            if "Do you want to" in stripped:
                if action_line:
                    arg = file_line or ""
                    tool_turn = {"type": "tool", "name": action_line.split()[0], "arg": f"{action_line}: {arg}", "output": code_lines[:20]}
                    turns.append(tool_turn)
                current_turn = {"type": "approval", "options": []}
                turns.append(current_turn)
                continue
            opt_match = re.match(r'^[❯\s]*(\d+)\.\s+(.+)$', stripped)
            if opt_match:
                if not current_turn or current_turn.get("type") != "approval":
                    current_turn = {"type": "approval", "options": []}
                    turns.append(current_turn)
                current_turn["options"].append(f"{opt_match.group(1)}. {opt_match.group(2)}")
                continue
        return turns

    for line in lines:
        stripped = line.strip()
        if not stripped or SEP_RE.match(stripped):
            continue
        if any(stripped.startswith(p) for p in skip_patterns):
            continue
        if stripped in ("Running…", "Waiting…"):
            continue
        if re.match(r'^PR\s+#', stripped):
            continue
        if stripped == "❯":
            continue
        if "Do you want to" in stripped:
            current_turn = {"type": "approval", "options": []}
            turns.append(current_turn)
            continue
        if current_turn and current_turn.get("type") == "approval":
            opt_match = re.match(r'^[❯\s]*(\d+)\.\s+(.+)$', stripped)
            if opt_match:
                current_turn["options"].append(f"{opt_match.group(1)}. {opt_match.group(2)}")
                continue
        if stripped.startswith("❯"):
            user_text = stripped[1:].strip()
            if user_text and not re.match(r'^\d+\.', user_text):
                current_turn = {"type": "user", "text": user_text}
                turns.append(current_turn)
            continue
        tool_match = re.match(r'^⏺\s+(\w+)\((.+?)\)\s*$', stripped)
        if tool_match:
            current_turn = {"type": "tool", "name": tool_match.group(1), "arg": tool_match.group(2), "output": []}
            turns.append(current_turn)
            continue
        if stripped.startswith("⏺"):
            text = stripped[1:].strip()
            if text:
                current_turn = {"type": "claude", "text": text}
                turns.append(current_turn)
            continue
        if stripped.startswith("⎿"):
            output_text = stripped[1:].strip()
            if current_turn and current_turn.get("type") == "tool":
                if output_text and output_text not in ("Running…", "Waiting…"):
                    current_turn["output"].append(output_text)
            continue
        if current_turn and current_turn.get("type") == "tool" and re.match(r'^\d+\s', stripped):
            current_turn["output"].append(stripped)
            continue
        if current_turn and current_turn.get("type") == "tool" and line and not line[0].isalpha() and line[0] != "⏺":
            if stripped and stripped not in ("Running…", "Waiting…"):
                if not stripped.startswith("⏺") and "Do you want" not in stripped:
                    current_turn["output"].append(stripped)
                    continue
        if re.match(r'^[✶✻⏳]', stripped):
            current_turn = {"type": "status", "text": stripped}
            turns.append(current_turn)
            continue
        if current_turn:
            if current_turn["type"] == "claude":
                current_turn["text"] += "\n" + stripped
            elif current_turn["type"] == "tool":
                current_turn["output"].append(stripped)
            elif current_turn["type"] == "user":
                current_turn["text"] += "\n" + stripped
    return turns


EXT_LANG = {
    ".json": "json", ".js": "javascript", ".jsx": "javascript",
    ".ts": "typescript", ".tsx": "typescript",
    ".py": "python", ".rb": "ruby", ".go": "go", ".rs": "rust",
    ".html": "html", ".css": "css", ".scss": "css",
    ".sql": "sql", ".sh": "bash", ".bash": "bash", ".zsh": "bash",
    ".yaml": "yaml", ".yml": "yaml", ".toml": "toml",
    ".xml": "xml", ".md": "markdown", ".graphql": "graphql",
    ".swift": "swift", ".kt": "kotlin", ".java": "java",
    ".c": "c", ".cpp": "cpp", ".h": "c", ".cs": "csharp",
    ".php": "php", ".lua": "lua", ".r": "r",
    ".env": "bash", ".conf": "bash", ".ini": "ini",
}


def detect_code_lang(arg, lines):
    for ext, lang in EXT_LANG.items():
        if arg.lower().endswith(ext):
            return lang
        if ext in arg.lower():
            return lang
    text = "\n".join(lines[:5])
    if text.strip().startswith("{") or text.strip().startswith("["):
        return "json"
    if "SELECT " in text or "INSERT " in text or "CREATE TABLE" in text:
        return "sql"
    if text.strip().startswith("<!DOCTYPE") or text.strip().startswith("<html"):
        return "html"
    if "#!/bin/" in text:
        return "bash"
    has_code_lines = any(re.match(r'^\s*\d+\s', l) for l in lines[:5])
    if has_code_lines:
        return "typescript"
    return None


def format_turns(turns):
    parts = []
    in_claude_block = False
    claude_lines = []
    has_truncated_output = False  # Track if any output was truncated by Claude Code

    def flush_claude():
        nonlocal in_claude_block, claude_lines
        if claude_lines:
            block = "\n".join(claude_lines)
            parts.append(f"🤖 Claude:\n{block}")
            claude_lines = []
        in_claude_block = False

    for turn in turns:
        t = turn["type"]
        if t == "user":
            flush_claude()
            parts.append(f"🧑 You: {turn['text']}")
        elif t == "claude":
            in_claude_block = True
            claude_lines.append(turn["text"])
        elif t == "tool":
            in_claude_block = True
            output_lines = turn.get("output", [])
            output = "\n".join(output_lines)
            # Check if Claude Code truncated the output ("+N lines (ctrl+o to expand)")
            truncated_match = None
            for ol in output_lines:
                m = TRUNCATED_RE.search(ol)
                if m:
                    truncated_match = m
                    has_truncated_output = True
                    break

            if output:
                if len(output) > 400:
                    output = output[:400] + "\n  … (truncated)"
                is_edit = turn["name"] in ("Edit", "Write", "Update")
                has_diff = any(
                    re.match(r'^\d+\s*[+\-]', l) or
                    l.strip().startswith("Added ") or
                    l.strip().startswith("Removed ")
                    for l in output_lines[:10]
                )
                if is_edit or has_diff:
                    diff_lines = []
                    for l in output_lines:
                        m = re.match(r'^(\d+)\s*\+\s*(.*)', l)
                        if m:
                            diff_lines.append(f"+ {m.group(1).rjust(3)} │ {m.group(2)}")
                            continue
                        m = re.match(r'^(\d+)\s*\-\s*(.*)', l)
                        if m:
                            diff_lines.append(f"- {m.group(1).rjust(3)} │ {m.group(2)}")
                            continue
                        if l.strip().startswith("Added ") or l.strip().startswith("Removed "):
                            diff_lines.append(f"# {l.strip()}")
                            continue
                        if "lines (ctrl+o" in l or TRUNCATED_RE.search(l):
                            hidden = TRUNCATED_RE.search(l)
                            n = hidden.group(1) if hidden else "?"
                            diff_lines.append(f"# ⚠️ {n} more lines collapsed")
                            continue
                        if l.strip().startswith("…") and "lines" not in l:
                            diff_lines.append(f"# {l.strip()}")
                            continue
                        m = re.match(r'^(\d+)\s+(.*)', l)
                        if m:
                            diff_lines.append(f"  {m.group(1).rjust(3)} │ {m.group(2)}")
                        else:
                            diff_lines.append(f"  {l}")
                    diff_text = "\n".join(diff_lines[:30])
                    if len(diff_lines) > 30:
                        diff_text += "\n# … (truncated)"
                    claude_lines.append(f"  ⚡ {turn['name']}({turn['arg']})")
                    claude_lines.append(f"```diff\n{diff_text}\n```")
                elif turn["name"] == "Bash":
                    cmd = turn["arg"]
                    actual_output = []
                    cmd_echo = []
                    found_output = False
                    for ol in output_lines:
                        if found_output:
                            actual_output.append(ol)
                        elif ol.strip().startswith("===") or ol.strip() in ("PASS", "FAIL") or ol.strip().startswith("Response:") or ol.strip().startswith("Error:") or ol.strip().startswith("Results:") or ol.strip().startswith("{") or ol.strip().startswith("["):
                            found_output = True
                            actual_output.append(ol)
                        elif "lines (ctrl+o" in ol or TRUNCATED_RE.search(ol):
                            hidden = TRUNCATED_RE.search(ol)
                            n = hidden.group(1) if hidden else "?"
                            actual_output.append(f"⚠️ {n} more lines collapsed")
                        elif ol.strip().startswith("…") and "lines" not in ol:
                            actual_output.append(ol)
                        else:
                            cmd_echo.append(ol)
                    if cmd.endswith("…)") or cmd.endswith("…"):
                        full_cmd = cmd
                        if cmd_echo:
                            full_cmd = cmd.rstrip(")") + "\n" + "\n".join(cmd_echo)
                        claude_lines.append(f"  ⚡ Bash:")
                        claude_lines.append(f"```bash\n{full_cmd}\n```")
                    else:
                        claude_lines.append(f"  ⚡ Bash:")
                        claude_lines.append(f"```bash\n{cmd}\n```")
                    if actual_output:
                        out_lang = detect_code_lang("", actual_output)
                        out_text = "\n".join(actual_output[:20])
                        if len(actual_output) > 20:
                            out_text += "\n… (truncated)"
                        claude_lines.append(f"📤 Output:")
                        claude_lines.append(f"```{out_lang or ''}\n{out_text}\n```")
                    elif cmd_echo and not cmd.endswith("…)") and not cmd.endswith("…"):
                        out_text = "\n".join(cmd_echo[:20])
                        claude_lines.append(f"📤 Output:")
                        claude_lines.append(f"```\n{out_text}\n```")
                else:
                    lang = detect_code_lang(turn["arg"], output_lines)
                    if lang:
                        code_text = "\n".join(output_lines[:30])
                        if len(output_lines) > 30:
                            code_text += "\n// … (truncated)"
                        claude_lines.append(f"  ⚡ {turn['name']}({turn['arg']})")
                        claude_lines.append(f"```{lang}\n{code_text}\n```")
                    else:
                        claude_lines.append(f"  ⚡ {turn['name']}({turn['arg']})\n  → {output}")
            else:
                claude_lines.append(f"  ⚡ {turn['name']}({turn['arg']}) ⏳")
        elif t == "approval":
            in_claude_block = True
            opts = "\n  ".join(turn.get("options", []))
            claude_lines.append(f"  🟡 Approve?\n  {opts}")
        elif t == "status":
            in_claude_block = True
            status_text = turn["text"]
            # Clean up terminal UI symbols with better-looking ones
            status_text = re.sub(r'^[✻✶]', '🔮', status_text)
            status_text = re.sub(r'[✢]', '✨', status_text)
            status_text = re.sub(r'⏵+', '▶', status_text)
            # Remove terminal-only hints
            status_text = re.sub(r'\s*·\s*esc\b.*$', '', status_text, flags=re.IGNORECASE)
            status_text = re.sub(r'\s*shift\+tab.*$', '', status_text, flags=re.IGNORECASE)
            status_text = re.sub(r'\s*\(shift\+tab.*?\)', '', status_text)
            claude_lines.append(f"  {status_text.strip()}")
    flush_claude()

    # If truncated output detected, add a note at the end
    if has_truncated_output:
        pass  # Don't add verbose truncation warning — the inline note is enough

    return "\n\n".join(parts)


def telegram_api(method, params):
    try:
        data = urllib.parse.urlencode(params).encode()
        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/{method}",
            data=data
        )
        resp = urllib.request.urlopen(req, timeout=10)
        return json.loads(resp.read().decode())
    except Exception:
        return {"ok": False}


def send_document(filename, content, caption=""):
    """Send content as a .txt file attachment via Telegram's sendDocument API."""
    tmp = None
    try:
        tmp = tempfile.NamedTemporaryFile(mode="w", suffix=f"_{filename}", delete=False)
        tmp.write(content)
        tmp.close()

        boundary = "----TelegramBotBoundary"
        body_parts = []
        # chat_id field
        body_parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"chat_id\"\r\n\r\n{CHAT_ID}")
        # caption field
        if caption:
            body_parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"caption\"\r\n\r\n{caption}")
        # disable_notification field
        body_parts.append(f"--{boundary}\r\nContent-Disposition: form-data; name=\"disable_notification\"\r\n\r\ntrue")
        # document file field
        with open(tmp.name, "rb") as f:
            file_data = f.read()
        body_parts.append(
            f"--{boundary}\r\nContent-Disposition: form-data; name=\"document\"; filename=\"{filename}\"\r\n"
            f"Content-Type: text/plain\r\n\r\n"
        )
        # Build multipart body as bytes
        body_bytes = b""
        for part in body_parts[:-1]:
            body_bytes += part.encode() + b"\r\n"
        # Last part has file data
        body_bytes += body_parts[-1].encode()
        body_bytes += file_data
        body_bytes += f"\r\n--{boundary}--\r\n".encode()

        req = urllib.request.Request(
            f"https://api.telegram.org/bot{BOT_TOKEN}/sendDocument",
            data=body_bytes,
            headers={"Content-Type": f"multipart/form-data; boundary={boundary}"}
        )
        resp = urllib.request.urlopen(req, timeout=30)
        return json.loads(resp.read().decode()).get("ok", False)
    except Exception:
        return False
    finally:
        if tmp and os.path.exists(tmp.name):
            os.unlink(tmp.name)


def send_message(text, notify=False):
    text = redact_secrets(text)
    # If text exceeds Telegram's 4096 char limit, send summary + file attachment
    if len(text) > TELEGRAM_MAX_LEN:
        summary = text[:3800] + "\n\n... (truncated) full output attached"
        silent = "false" if notify else "true"
        resp = telegram_api("sendMessage", {
            "chat_id": CHAT_ID, "text": summary,
            "parse_mode": "Markdown", "disable_notification": silent,
        })
        if not resp.get("ok"):
            resp = telegram_api("sendMessage", {
                "chat_id": CHAT_ID, "text": summary, "disable_notification": silent,
            })
        msg_id = resp.get("result", {}).get("message_id") if resp.get("ok") else None
        send_document("full_output.txt", text, caption="Full output attached")
        return msg_id
    silent = "false" if notify else "true"
    resp = telegram_api("sendMessage", {
        "chat_id": CHAT_ID, "text": text,
        "parse_mode": "Markdown", "disable_notification": silent,
    })
    if not resp.get("ok"):
        resp = telegram_api("sendMessage", {
            "chat_id": CHAT_ID, "text": text, "disable_notification": silent,
        })
    if resp.get("ok"):
        return resp["result"]["message_id"]
    return None


def edit_message(message_id, text):
    text = redact_secrets(text)
    resp = telegram_api("editMessageText", {
        "chat_id": CHAT_ID, "message_id": message_id,
        "text": text, "parse_mode": "Markdown",
    })
    if not resp.get("ok"):
        resp = telegram_api("editMessageText", {
            "chat_id": CHAT_ID, "message_id": message_id, "text": text,
        })
    return resp.get("ok", False)


def pin_message(message_id):
    """Pin a message in the Telegram chat."""
    return telegram_api("pinChatMessage", {
        "chat_id": CHAT_ID,
        "message_id": message_id,
        "disable_notification": "true",
    })


def unpin_message(message_id):
    """Unpin a specific message in the Telegram chat."""
    return telegram_api("unpinChatMessage", {
        "chat_id": CHAT_ID,
        "message_id": message_id,
    })


# Track pinned error messages for auto-unpin after 5 minutes
_pinned_messages = []  # list of (message_id, pin_time)


def check_unpin_expired():
    """Unpin messages that were pinned more than 5 minutes ago."""
    now = time.time()
    still_pinned = []
    for msg_id, pin_time in _pinned_messages:
        if now - pin_time >= 300:
            unpin_message(msg_id)
        else:
            still_pinned.append((msg_id, pin_time))
    _pinned_messages.clear()
    _pinned_messages.extend(still_pinned)


# Extended error patterns for detection
ERROR_KEYWORDS = [
    "error:", "failed", "crash", "exception", "fatal",
    "permission denied", "not found", "timed out",
    "enoent", "eacces", "etimedout", "oom", "killed",
    "segfault", "syntax error", "typeerror", "referenceerror",
    "importerror", "modulenotfounderror",
]


def detect_notification(turns):
    """Detect if the current terminal state warrants a phone notification.
    Returns (should_notify: bool, summary: str, is_error: bool).
    The summary is a short string shown as the first line for phone notifications."""
    if not turns:
        return False, "", False

    last = turns[-1]

    # Approval prompt -> always notify
    if last.get("type") == "approval":
        return True, "", False  # approval_block handles its own format

    # Check for completion / error signals in Claude's output
    for turn in reversed(turns[-5:]):
        if turn.get("type") == "claude":
            text = turn.get("text", "")
            text_lower = text.lower()
            # Skip error detection in commit messages, descriptions, and fix notes
            is_descriptive = any(phrase in text_lower for phrase in [
                "fix ", "fixed ", "fixing ", "commit", "pushed",
                "refactor", "renamed", "replaced", "updated",
                "co-authored", "the issue was", "the error was",
                "let me fix", "i found the", "resolved",
            ])
            # Error / failure (check first -- higher priority)
            if not is_descriptive and any(w in text_lower for w in ERROR_KEYWORDS):
                # Extract first meaningful line as summary
                first_line = text.split("\n")[0][:80].strip()
                return True, f"❌ {first_line}", True
            # Task / build completed
            if any(w in text_lower for w in [
                "done", "complete", "finished", "all tests pass",
                "build succeeded", "committed", "pushed", "deployed",
                "created successfully", "no errors",
            ]):
                first_line = text.split("\n")[0][:80].strip()
                return True, f"✅ {first_line}", False
        if turn.get("type") == "status":
            text = turn.get("text", "").lower()
            if "complete" in text or "done" in text or "finished" in text:
                return True, "✅ Task complete", False

    return False, "", False


def extract_approval_block(raw):
    if "Do you want to" not in raw:
        return None
    lines = raw.split("\n")
    content_lines = []
    approval = []
    started = False
    in_approval = False
    for l in lines:
        s = l.strip()
        if s.startswith("Esc to cancel") or s.startswith("Tab to amend"):
            continue
        if not started:
            if SEP_RE.match(s):
                started = True
            continue
        if "Do you want to" in s:
            in_approval = True
            approval.append(s)
            continue
        if in_approval:
            opt = re.match(r'^[❯\s]*(\d+)\.\s+(.+)$', s)
            if opt:
                approval.append(f"{opt.group(1)}. {opt.group(2)}")
            continue
        if re.match(r'^[╌]+$', s):
            continue
        if SEP_RE.match(s):
            continue
        if s:
            content_lines.append(s)
    if not approval:
        return None

    action = None
    file_path = None
    cmd_lines = []
    code_lines = []
    info_lines = []
    collecting_cmd = False
    for s in content_lines:
        if s in ("Create file", "Edit file", "Bash command", "Write file", "Read file"):
            action = s
            if action == "Bash command":
                collecting_cmd = True
            continue
        if re.match(r'^\s*\d+\s', s):
            collecting_cmd = False
            code_lines.append(s)
            continue
        if collecting_cmd:
            looks_like_code = (
                s.startswith("-") or s.startswith("'") or s.startswith('"') or
                s.startswith("|") or s.startswith("\\") or s.startswith("d=") or
                s.startswith("import ") or s.startswith("print(") or
                "=" in s[:15] or
                any(c in s for c in ["{", "}", "()", "$", "`", "&&", "||", "curl", "python", "grep", "sed", "awk"])
            )
            looks_like_desc = len(s) < 80 and len(s) > 0 and s[0].isupper() and not looks_like_code
            if looks_like_desc and cmd_lines:
                collecting_cmd = False
                info_lines.append(s)
            else:
                cmd_lines.append(s)
            continue
        if action and not file_path and not cmd_lines:
            file_path = s
            continue
        info_lines.append(s)

    msg = "🟡 Approval Required\n\n"
    if action == "Bash command" and cmd_lines:
        msg += f"⚡ Command:\n```bash\n{chr(10).join(cmd_lines)}\n```\n"
        if info_lines:
            msg += "\n".join(info_lines) + "\n\n"
    elif action == "Bash command" and file_path:
        msg += f"⚡ Command:\n```bash\n{file_path}\n```\n"
        if info_lines:
            msg += "\n".join(info_lines) + "\n\n"
    elif action and file_path:
        msg += f"📄 {action}: {file_path}\n\n"
        if info_lines:
            msg += "\n".join(info_lines) + "\n\n"
    elif action:
        msg += f"📄 {action}\n\n"

    if code_lines:
        is_diff = any(re.match(r'^\s*\d+\s*[+\-]', cl) for cl in code_lines[:10])
        if is_diff:
            diff_lines = []
            for cl in code_lines[:25]:
                m = re.match(r'^\s*(\d+)\s*\+\s*(.*)', cl)
                if m:
                    diff_lines.append(f"+ {m.group(1).rjust(3)} │ {m.group(2)}")
                    continue
                m = re.match(r'^\s*(\d+)\s*\-\s*(.*)', cl)
                if m:
                    diff_lines.append(f"- {m.group(1).rjust(3)} │ {m.group(2)}")
                    continue
                m = re.match(r'^\s*(\d+)\s+(.*)', cl)
                if m:
                    diff_lines.append(f"  {m.group(1).rjust(3)} │ {m.group(2)}")
            if diff_lines:
                diff_text = "\n".join(diff_lines)
                if len(code_lines) > 25:
                    diff_text += "\n# … (truncated)"
                msg += f"```diff\n{diff_text}\n```\n\n"
        else:
            lang = detect_code_lang(file_path or "", code_lines)
            plain_lines = []
            for cl in code_lines[:25]:
                m = re.match(r'^\s*\d+\s+(.*)', cl)
                if m:
                    plain_lines.append(m.group(1))
                else:
                    plain_lines.append(cl)
            code_text = "\n".join(plain_lines)
            if len(code_lines) > 25:
                code_text += "\n// … (truncated)"
            msg += f"```{lang or ''}\n{code_text}\n```\n\n"

    msg += "\n".join(approval)
    return msg


def detect_task_state(turns):
    """Detect the current task state from parsed turns.
    Returns: (state, active_tool, detail)
    States: 'working', 'tool', 'approval', 'complete', 'error', 'idle'
    """
    if not turns:
        return "idle", None, None

    last = turns[-1]

    # Approval prompt
    if last.get("type") == "approval":
        return "approval", None, None

    # Check last few turns for state
    for turn in reversed(turns[-5:]):
        if turn.get("type") == "tool":
            output = turn.get("output", [])
            if not output or output == []:
                return "tool", turn.get("name", ""), turn.get("arg", "")
            # Tool with output = probably done with that tool
            continue
        if turn.get("type") == "claude":
            text = turn.get("text", "").lower()
            # Error detection
            if any(w in text for w in ["error:", "failed", "crash", "exception", "fatal"]):
                return "error", None, turn.get("text", "").split("\n")[0][:60]
            # Completion detection
            if any(w in text for w in ["done", "complete", "finished", "all tests pass", "committed", "pushed"]):
                return "complete", None, turn.get("text", "").split("\n")[0][:60]
        if turn.get("type") == "status":
            return "working", None, turn.get("text", "")[:60]

    # Default: working
    return "working", None, None


def format_status_footer(state, active_tool, detail, elapsed_secs, tick):
    """Generate the status footer line for a message."""
    hourglass = "⏳" if tick % 2 == 0 else "⌛"
    elapsed = format_elapsed(elapsed_secs)

    if state == "approval":
        return f"🟡 Awaiting approval ({elapsed})"
    elif state == "tool":
        tool_name = active_tool or "tool"
        tool_arg = f": {detail}" if detail else ""
        return f"⚡ Running {tool_name}{tool_arg} ({elapsed})"
    elif state == "complete":
        return f"✅ Done in {elapsed}"
    elif state == "error":
        return f"❌ Error after {elapsed}"
    elif state == "idle":
        return f"💤 Idle ({elapsed})"
    else:
        return f"{hourglass} Working... ({elapsed})"


def format_elapsed(secs):
    """Format seconds into human-readable elapsed time."""
    secs = int(secs)
    if secs < 60:
        return f"{secs}s"
    elif secs < 3600:
        return f"{secs // 60}m {secs % 60}s"
    else:
        return f"{secs // 3600}h {(secs % 3600) // 60}m"


def get_header_for_state(state):
    """Return the header emoji suffix for a given task state."""
    state_icons = {
        "working": "⏳",
        "tool": "⚡",
        "approval": "🟡",
        "complete": "✅",
        "error": "❌",
        "idle": "💤",
    }
    return state_icons.get(state, "⏳")


def main():
    header_base = f"🖥 {PROJECT_NAME} Terminal"
    header_ended = f"🖥 {PROJECT_NAME} Terminal (ended)"

    prev_content = get_terminal_content()
    live_msg_id = None
    live_msg_text = ""
    last_user_count = 0
    prev_had_approval = False
    task_start_time = time.time()
    tick_count = 0

    # Heartbeat and idle tracking
    iteration_count = 0
    last_change_time = time.time()
    idle_notified = False

    while os.path.exists(ACTIVE_FLAG):
        time.sleep(3)
        iteration_count += 1

        # Write heartbeat every 60 seconds (20 iterations at 3s interval)
        if iteration_count % 20 == 0:
            try:
                with open(HEARTBEAT_FILE, "w") as hf:
                    hf.write(str(int(time.time())))
            except OSError:
                pass

        # Check for expired pinned messages
        check_unpin_expired()

        curr_content = get_terminal_content()
        if not curr_content or curr_content == prev_content:
            # Check idle timeout
            if not idle_notified and (time.time() - last_change_time) >= IDLE_TIMEOUT:
                idle_minutes = int((time.time() - last_change_time) / 60)
                send_message(f"💤 Terminal idle for {idle_minutes} minutes")
                idle_notified = True
            continue

        # Content changed — reset idle tracking
        last_change_time = time.time()
        idle_notified = False
        prev_content = curr_content

        has_approval = "Do you want to" in curr_content
        approval_block = extract_approval_block(curr_content) if has_approval else None

        if prev_had_approval and not has_approval:
            if live_msg_id:
                final = live_msg_text.replace("🟡 Approval Required", "🟡 Approved ✓")
                edit_message(live_msg_id, final)
                live_msg_id = None
                live_msg_text = ""
            task_start_time = time.time()  # Reset timer after approval
            processed = preprocess_tables(curr_content)
            turns = parse_terminal(processed)
            if turns:
                formatted = format_turns(turns)
                if formatted:
                    state, tool, detail = detect_task_state(turns)
                    header = f"{header_base} {get_header_for_state(state)}"
                    footer = format_status_footer(state, tool, detail, time.time() - task_start_time, tick_count)
                    display = f"{header}\n\n{formatted}\n\n{footer}"
                    if len(display) > MAX_MSG_LEN:
                        display = display[:MAX_MSG_LEN]
                    live_msg_id = send_message(display)
                    if live_msg_id:
                        live_msg_text = display
            prev_had_approval = False
            continue

        if approval_block and not prev_had_approval:
            if live_msg_id:
                state, _, _ = detect_task_state(parse_terminal(preprocess_tables(prev_content)))
                header_with_state = f"{header_base} {get_header_for_state('complete')}"
                final = live_msg_text
                # Replace any header variant with the completed one
                for icon in ["⏳", "⌛", "⚡", "🟡", "❌", "💤"]:
                    final = final.replace(f"{header_base} {icon}", header_with_state)
                edit_message(live_msg_id, final)
                live_msg_id = None
                live_msg_text = ""
            # Approvals always push-notify the user's phone
            live_msg_id = send_message(approval_block, notify=True)
            if live_msg_id:
                live_msg_text = approval_block
            prev_had_approval = True
            continue

        if has_approval:
            if approval_block and approval_block != live_msg_text and live_msg_id:
                edit_message(live_msg_id, approval_block)
                live_msg_text = approval_block
            prev_had_approval = True
            continue

        prev_had_approval = False
        processed = preprocess_tables(curr_content)
        turns = parse_terminal(processed)
        if not turns:
            continue

        tick_count += 1

        user_count = sum(1 for t in turns if t["type"] == "user")
        if user_count > last_user_count and live_msg_id:
            # New user message — finalize previous message with ✅
            header_complete = f"{header_base} ✅"
            final = live_msg_text
            for icon in ["⏳", "⌛", "⚡", "🟡", "❌", "💤"]:
                final = final.replace(f"{header_base} {icon}", header_complete)
            # Update footer to "Done"
            elapsed = time.time() - task_start_time
            final = re.sub(r'\n\n[⏳⌛⚡🟡✅❌💤].*$', f"\n\n✅ Done in {format_elapsed(elapsed)}", final)
            edit_message(live_msg_id, final)
            live_msg_id = None
            live_msg_text = ""
            task_start_time = time.time()  # Reset timer for new task
        last_user_count = user_count

        last_user_idx = -1
        for i in range(len(turns) - 1, -1, -1):
            if turns[i]["type"] == "user":
                last_user_idx = i
                break
        start = last_user_idx if last_user_idx >= 0 else max(0, len(turns) - 15)
        visible = turns[start:]
        formatted = format_turns(visible)
        if not formatted:
            continue

        # Detect task state and build status footer
        state, active_tool, detail = detect_task_state(visible)
        elapsed_secs = time.time() - task_start_time
        header = f"{header_base} {get_header_for_state(state)}"
        footer = format_status_footer(state, active_tool, detail, elapsed_secs, tick_count)

        # Detect if this update warrants a phone notification
        should_notify, notify_summary, is_error = detect_notification(visible)

        # Prepend short summary for phone notification preview
        if should_notify and notify_summary:
            display = f"{notify_summary}\n\n{header}\n\n{formatted}\n\n{footer}"
        else:
            display = f"{header}\n\n{formatted}\n\n{footer}"
        while len(display) > MAX_MSG_LEN:
            lines = display.split("\n")
            if len(lines) > 5:
                display = "\n".join(lines[:3] + ["…"] + lines[5:])
            else:
                display = display[-MAX_MSG_LEN:]
                break

        # Compare content WITHOUT the timer footer to avoid unnecessary updates
        def strip_footer(text):
            return re.sub(r'\n\n[⏳⌛⚡🟡✅❌💤].*$', '', text)

        content_changed = strip_footer(display) != strip_footer(live_msg_text)

        if live_msg_id:
            if content_changed or should_notify:
                if should_notify:
                    # Important update: send as new message with notification
                    header_complete = f"{header_base} ✅"
                    final = live_msg_text
                    for icon in ["⏳", "⌛", "⚡", "🟡", "❌", "💤"]:
                        final = final.replace(f"{header_base} {icon}", header_complete)
                    edit_message(live_msg_id, final)
                    live_msg_id = send_message(display, notify=True)
                    if live_msg_id:
                        live_msg_text = display
                        # Pin error messages for visibility
                        if is_error:
                            pin_message(live_msg_id)
                            _pinned_messages.append((live_msg_id, time.time()))
                elif edit_message(live_msg_id, display):
                    live_msg_text = display
                # If edit fails, DON'T send a new message — just wait for next cycle
        else:
            live_msg_id = send_message(display, notify=should_notify)
            if live_msg_id:
                live_msg_text = display
                # Pin error messages for visibility
                if is_error:
                    pin_message(live_msg_id)
                    _pinned_messages.append((live_msg_id, time.time()))

    if live_msg_id:
        final = live_msg_text
        for icon in ["⏳", "⌛", "⚡", "🟡", "✅", "❌", "💤"]:
            final = final.replace(f"{header_base} {icon}", header_ended)
        # Replace footer with ended status
        elapsed = time.time() - task_start_time
        final = re.sub(r'\n\n[⏳⌛⚡🟡✅❌💤].*$', f"\n\n🔴 Session ended ({format_elapsed(elapsed)})", final)
        edit_message(live_msg_id, final)

    # Clean up heartbeat file
    try:
        os.remove(HEARTBEAT_FILE)
    except OSError:
        pass

    try:
        os.remove(PID_FILE)
    except OSError:
        pass


if __name__ == "__main__":
    main()
