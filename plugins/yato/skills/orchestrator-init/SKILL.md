---
name: orchestrator-init
description: Initialize a new project with PM and Developer agents in tmux
user-invocable: false
disable-model-invocation: true
---

# Initialize Orchestrator Project

You are initializing a new tmux orchestrator project.

## Arguments
- session: Tmux session name for the project (required)
- path: Project directory path (will be created if doesn't exist) (required)

## Steps

1. **Initialize the project** (creates session + PM + Developer):
```bash
cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/orchestrator.py init <session> -p <path>
```

2. **Start Claude in all agent windows:**
```bash
cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/orchestrator.py start
```

3. **Report the result** to the user, including:
   - Session name created
   - Agent windows created (PM at :1, Developer at :2)
   - How to brief the PM with project requirements
   - How to monitor progress

## Next Steps for User

After initialization, the user should brief the PM:
```bash
cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/tmux_utils.py send <session>:1 "Your project requirements here"
```
