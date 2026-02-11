---
name: orchestrator-deploy
description: Deploy a custom team from a configuration file
user-invocable: false
disable-model-invocation: true
---

# Deploy Custom Team

You are deploying a custom team configuration.

## Arguments
- session: Tmux session name for the project (required)
- path: Project directory path (required)
- config: Path to team configuration JSON file (required)

## Team Config Format

The config file should be a JSON array of agent definitions:
```json
[
  {"role": "pm"},
  {"role": "developer", "name": "Frontend-Dev"},
  {"role": "developer", "name": "Backend-Dev"},
  {"role": "qa"}
]
```

## Steps

1. **Set the orchestrator path:**
```bash
YATO_PATH="${CLAUDE_PLUGIN_ROOT}"
```

2. **Deploy the team:**
```bash
python3 $YATO_PATH/lib/orchestrator.py deploy $ARGUMENTS -p <path> -c <config>
```

3. **Start Claude in all windows:**
```bash
python3 $YATO_PATH/lib/orchestrator.py start
```

4. **Show the deployed team structure** to the user with agent IDs and roles.
