---
name: tmux-message
model: sonnet
context: fork
description: Send a formatted two-way message to another tmux session or window, including sender identity and reply instructions. Use this skill whenever you need to send a message to another tmux session, communicate with another agent, notify a session, relay information to a different tmux window, or establish two-way communication between tmux sessions.
allowed-tools: Bash
---

# Tmux Message

<context>
Sends a formatted message to any tmux pane using stable pane IDs. The message header tells the recipient who sent it (FROM) and who they are (TO), enabling two-way communication.

CRITICAL RULES:
1. NEVER use `tmux display-message` — it returns WRONG values from Bash subprocesses
2. Always use tmux pane IDs (e.g., `%88`) — they are globally unique and stable even when panes are added/removed
3. Your own pane ID MUST come from the user prompt, or extracted from the TO field of a received message. If unknown, ASK the user.
</context>

<instructions>

## Sending a Message

Required info:
1. **Target pane ID** - where to send (e.g., `%92`)
2. **Message** - what to say
3. **Your pane ID** - for the reply address. If unknown, ASK the user — do NOT guess or auto-detect.

### Send Command

The entire message MUST be a single line — tmux send-keys treats newlines as Enter keypresses.

```bash
tmux send-keys -t "%92" "[MESSAGE FROM: %88 TO: %92] Hello! | To reply, use /tmux-message targeting %88" && sleep 1 && tmux send-keys -t "%92" Enter
```

Format: `[MESSAGE FROM: <YOUR_ID> TO: <TARGET_ID>] <message> | To reply, use /tmux-message targeting <YOUR_ID>`

## Replying to a Message

When you receive `[MESSAGE FROM: %88 TO: %92] ... | To reply, use /tmux-message targeting %88`:
- Your pane ID = the `TO` value (`%92`)
- Reply target = the `FROM` value (`%88`)

Use these values to reply:
```bash
tmux send-keys -t "%88" "[MESSAGE FROM: %92 TO: %88] Your reply | To reply, use /tmux-message targeting %92" && sleep 1 && tmux send-keys -t "%88" Enter
```

## Important Notes

- `sleep 1` between text and Enter is required — Claude Code needs time to receive the full message
- Pane IDs (`%N`) are globally unique and stable — they survive layout changes
- Do NOT use `tmux display-message` to detect your pane — it returns wrong values in skill forks

---

## Self-Update Protocol

After using this skill, update it when you discover edge cases or improvements.

### Discoveries log
<!-- Append entries here after real-world usage -->
</instructions>
