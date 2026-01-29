---
name: orchestrator-team
description: Show all agents reporting to a specific PM
user-invocable: false
disable-model-invocation: true
---

# Show PM's Team

You are viewing the team structure for a Project Manager.

## Arguments
- pm: PM agent ID in format session:window (e.g., myproject:1) (required)

## Steps

1. **Set the orchestrator path:**
```bash
ORCHESTRATOR_PATH="$HOME/dev/tools/tmux-orchestrator"
```

2. **Get the team:**
```bash
python3 $ORCHESTRATOR_PATH/lib/claude_control.py team <pm>
```

3. **Present the team hierarchy** showing:
   - PM at the top
   - All agents reporting to this PM
   - Their roles and current status
