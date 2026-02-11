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
YATO_PATH="${CLAUDE_PLUGIN_ROOT}"
```

2. **Show registered agents for current workflow:**
```bash
# From project directory (auto-detects workflow)
python3 $YATO_PATH/lib/claude_control.py status

# Or specify project path explicitly
python3 $YATO_PATH/lib/claude_control.py -p /path/to/project status
```

3. **List all tmux sessions and windows:**
```bash
python3 $YATO_PATH/lib/claude_control.py list -v
```

4. **Present the results** in a clear table format showing:
   - Workflow name
   - Active sessions
   - Registered agents with their roles and models
   - Window targets
