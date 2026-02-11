---
name: orchestrator-read
description: Read output from an agent window
user-invocable: false
disable-model-invocation: true
---

# Read Agent Output

You are reading the output from an orchestrator agent window.

## Arguments
- target: Target window in format session:window (e.g., myproject:1) (required)
- lines: Number of lines to capture (default 50) (optional)

## Steps

1. **Set the orchestrator path:**
```bash
YATO_PATH="${CLAUDE_PLUGIN_ROOT}"
```

2. **Capture the agent output:**
```bash
python3 $YATO_PATH/lib/claude_control.py read <target> -n <lines>
```

3. **Analyze the output** and summarize for the user:
   - What the agent is currently working on
   - Any errors or blockers mentioned
   - Progress on assigned tasks
   - Any requests or questions from the agent
