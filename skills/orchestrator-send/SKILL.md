---
name: orchestrator-send
description: Send a message to a specific agent window
user-invocable: false
disable-model-invocation: true
---

# Send Message to Agent

You are sending a message to an orchestrator agent.

## Arguments
- target: Target window in format session:window (e.g., myproject:1) (required)
- message: Message to send to the agent (required)

## Steps

1. **Send the message:**
```bash
cd ~/dev/tools/yato && uv run python lib/tmux_utils.py send <target> "<message>"
```

2. **Optionally read the response** after a few seconds:
```bash
cd ~/dev/tools/yato && uv run python lib/claude_control.py read <target> -n 30
```

3. **Confirm to the user** that the message was sent and show how to check for responses.
