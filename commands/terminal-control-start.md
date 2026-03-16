Activate Claude Code Telegram Agent — two-way Telegram synchronization.

Run this single command to activate everything:

```bash
~/claude-code-telegram-agent/scripts/start.sh
```

Confirm to the user that Remote Terminal is active. From this point on, all your tool activity (edits, commands, reads, searches) will be sent to Telegram automatically.

You MUST also periodically check for incoming Telegram messages by running:
```bash
~/claude-code-telegram-agent/scripts/check-inbox.sh
```
Do this after completing each task or action.

IMPORTANT rules for inbox checks:
- If the output is just a white dot `·`, there are NO messages. Say NOTHING about it — do not mention "no messages", do not say "standing by", do not comment on the empty inbox at all. Just silently continue your work.
- If the output contains a purple `📩 Telegram:` line, READ the message and follow the instructions. This is the user speaking to you from Telegram.
