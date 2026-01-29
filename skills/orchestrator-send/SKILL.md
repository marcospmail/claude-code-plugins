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

1. **Set the orchestrator path:**
```bash
ORCHESTRATOR_PATH="$HOME/dev/tools/tmux-orchestrator"
```

2. **Send the message:**
```bash
$ORCHESTRATOR_PATH/bin/send-message.sh <target> "<message>"
```

3. **Optionally read the response** after a few seconds:
```bash
python3 $ORCHESTRATOR_PATH/lib/claude_control.py read <target> -n 30
```

4. **Confirm to the user** that the message was sent and show how to check for responses.
