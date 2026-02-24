---
name: orchestrator-send
description: Send a message to a specific agent window
user-invocable: false
disable-model-invocation: true
---

# Send Message to Agent

You are sending a message to an orchestrator agent.

## Arguments
- target: Target agent — preferred format is global pane ID `%N` (e.g., `%5`); also accepts legacy `session:window` (e.g., `myproject:1`) (required)
- message: Message to send to the agent (required)

## Steps

1. **Send the message:**
```bash
uv run --project ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/tmux_utils.py send <target> "<message>"
```

2. **Optionally read the response** after a few seconds:
```bash
cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/claude_control.py read <target> -n 30
```

3. **Confirm to the user** that the message was sent and show how to check for responses.
