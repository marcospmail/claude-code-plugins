---
name: orchestrator-status
description: Show status of all registered agents and tmux sessions
user-invocable: false
disable-model-invocation: true
---

# Orchestrator Status

You are checking the status of all orchestrator agents.

## Steps

1. **Set the orchestrator path:**
```bash
YATO_PATH="$HOME/dev/tools/yato"
```

2. **Show registered agents:**
```bash
python3 $YATO_PATH/lib/claude_control.py status
```

3. **List all tmux sessions and windows:**
```bash
python3 $YATO_PATH/lib/claude_control.py list -v
```

4. **Present the results** in a clear table format showing:
   - Active sessions
   - Registered agents with their roles
   - Which agents report to which PM
   - Window names and paths
