---
name: orchestrator-team
description: Show all agents in the current workflow team
user-invocable: false
disable-model-invocation: true
---

# Show Workflow Team

You are viewing the team structure for the current workflow.

## Steps

1. **Set the orchestrator path:**
```bash
YATO_PATH="$HOME/dev/tools/yato"
```

2. **Get the team (from project directory):**
```bash
# From project directory (auto-detects workflow)
python3 $YATO_PATH/lib/claude_control.py team

# Or specify project path explicitly
python3 $YATO_PATH/lib/claude_control.py -p /path/to/project team
```

3. **Present the team hierarchy** showing:
   - Workflow name
   - PM at the top with target and model
   - All team members with their roles, targets, and models
