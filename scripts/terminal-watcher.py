#!/usr/bin/env python3
"""
Remote Terminal via Telegram — Terminal Watcher

Watches a Claude Code terminal session and mirrors output to Telegram
as self-editing messages with clean conversation formatting.

Reads config from config.json for project name, window matching, and Telegram credentials.
"""

import json, os, re, subprocess, time, urllib.request, urllib.parse

RTVT_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
ACTIVE_FLAG = os.path.join(RTVT_DIR, ".active")
PID_FILE = os.path.join(RTVT_DIR, ".watcher.pid")
CONFIG_FILE = os.path.join(RTVT_DIR, "config.json")

with open(CONFIG_FILE) as f:
    config = json.load(f)

BOT_TOKEN = config["telegram"]["bot_token"]
CHAT_ID = config["telegram"]["chat_id"]
PROJECT_NAME = config.get("project", {}).get("name", "Terminal")
WINDOW_MATCH = config.get("project", {}).get("window_match_string", "")
MAX_MSG_LEN = 3900

with open(PID_FILE, "w") as f:
    f.write(str(os.getpid()))

# AppleScript: if WINDOW_MATCH is empty, match ANY Claude Code window
# WINDOW_MATCH passed via argv to prevent injection
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

# Secret redaction patterns — masks sensitive data before sending to Telegram
SECRET_PATTERNS = [
    (re.compile(r'(sk-[a-zA-Z0-9]{20,})'), r'sk-***REDACTED***'),
    (re.compile(r'(ghp_[a-zA-Z0-9]{20,})'), r'ghp_***REDACTED***'),
    (re.compile(r'(gho_[a-zA-Z0-9]{20,})'), r'gho_***REDACTED***'),
    (re.compile(r'(AKIA[A-Z0-9]{12,})'), r'AKIA***REDACTED***'),
    (re.compile(r'([a-zA-Z_]*(?:PASSWORD|SECRET|TOKEN|API_KEY|PRIVATE_KEY|ACCESS_KEY)\s*[=:]\s*)\S+', re.IGNORECASE), r'\1***REDACTED***'),
    (re.compile(r'(Bearer\s+)[a-zA-Z0-9._\-]+'), r'\1***REDACTED***'),
    (re.compile(r'(\d{8,12}:[A-Za-z0-9_-]{30,})'), r'***BOT_TOKEN_REDACTED***'),
]


def redact_secrets(text):
    """Remove sensitive patterns from text before sending to Telegram."""
    for pattern, replacement in SECRET_PATTERNS:
        text = pattern.sub(replacement, text)
    return text


SEP_RE = re.compile(r'^[─━═╌┈┄\-]{10,}$')
TABLE_BORDER_RE = re.compile(r'^[┌┬┐├┼┤└┴┘─│╌┈]+$')
TABLE_ROW_RE = re.compile(r'^\s*│(.+)│\s*$')


def get_terminal_content():
    try:
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
                        if "lines (ctrl+o" in l or l.strip().startswith("…"):
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
                        elif "lines (ctrl+o" in ol or ol.strip().startswith("…"):
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
            status_text = re.sub(r'^[✻✶]', '🪸', turn["text"])
            claude_lines.append(f"  {status_text}")
    flush_claude()
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


def send_message(text):
    text = redact_secrets(text)
    resp = telegram_api("sendMessage", {
        "chat_id": CHAT_ID, "text": text,
        "parse_mode": "Markdown", "disable_notification": "true",
    })
    if not resp.get("ok"):
        resp = telegram_api("sendMessage", {
            "chat_id": CHAT_ID, "text": text, "disable_notification": "true",
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


def main():
    header = f"🖥 {PROJECT_NAME} Terminal"
    header_done = f"🖥 {PROJECT_NAME} Terminal ✓"
    header_ended = f"🖥 {PROJECT_NAME} Terminal (ended)"

    prev_content = get_terminal_content()
    live_msg_id = None
    live_msg_text = ""
    last_user_count = 0
    prev_had_approval = False

    while os.path.exists(ACTIVE_FLAG):
        time.sleep(3)

        curr_content = get_terminal_content()
        if not curr_content or curr_content == prev_content:
            continue

        prev_content = curr_content

        has_approval = "Do you want to" in curr_content
        approval_block = extract_approval_block(curr_content) if has_approval else None

        if prev_had_approval and not has_approval:
            if live_msg_id:
                final = live_msg_text.replace("🟡 Approval Required", "🟡 Approved ✓")
                edit_message(live_msg_id, final)
                live_msg_id = None
                live_msg_text = ""
            processed = preprocess_tables(curr_content)
            turns = parse_terminal(processed)
            if turns:
                formatted = format_turns(turns)
                if formatted:
                    display = f"{header}\n{'─' * 25}\n\n{formatted}"
                    if len(display) > MAX_MSG_LEN:
                        display = display[:MAX_MSG_LEN]
                    live_msg_id = send_message(display)
                    if live_msg_id:
                        live_msg_text = display
            prev_had_approval = False
            continue

        if approval_block and not prev_had_approval:
            if live_msg_id:
                final = live_msg_text.replace(header, header_done)
                edit_message(live_msg_id, final)
                live_msg_id = None
                live_msg_text = ""
            live_msg_id = send_message(approval_block)
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

        user_count = sum(1 for t in turns if t["type"] == "user")
        if user_count > last_user_count and live_msg_id:
            final = live_msg_text.replace(header, header_done)
            edit_message(live_msg_id, final)
            live_msg_id = None
            live_msg_text = ""
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

        display = f"{header}\n{'─' * 25}\n\n{formatted}"
        while len(display) > MAX_MSG_LEN:
            lines = display.split("\n")
            if len(lines) > 5:
                display = "\n".join(lines[:3] + ["…"] + lines[5:])
            else:
                display = display[-MAX_MSG_LEN:]
                break

        if live_msg_id:
            if display != live_msg_text:
                if edit_message(live_msg_id, display):
                    live_msg_text = display
                else:
                    live_msg_id = send_message(display)
                    if live_msg_id:
                        live_msg_text = display
        else:
            live_msg_id = send_message(display)
            if live_msg_id:
                live_msg_text = display

    if live_msg_id:
        final = live_msg_text.replace(header, header_ended)
        edit_message(live_msg_id, final)

    try:
        os.remove(PID_FILE)
    except OSError:
        pass


if __name__ == "__main__":
    main()
