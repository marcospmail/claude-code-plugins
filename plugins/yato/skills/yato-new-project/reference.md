# YAWF New Project - Reference

## Command Reference

### deploy-pm Command

```bash
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm SESSION_NAME -p PROJECT_PATH
```

**Parameters:**
- `SESSION_NAME`: Name for the tmux session (kebab-case recommended)
- `-p PROJECT_PATH`: Absolute path where the project will be located

**What it does:**
1. Creates a new tmux session with the specified name
2. Sets the working directory to the project path
3. Deploys a Project Manager agent in the session
4. Registers the agent in the orchestrator registry
5. Starts Claude in the PM window with proper briefing

### Clipboard Command

```bash
echo "tmux attach-session -t SESSION_NAME" | pbcopy
```

**Purpose:** Copies the attach command to the system clipboard for easy pasting.

**Alternative (Linux):**
```bash
echo "tmux attach-session -t SESSION_NAME" | xclip -selection clipboard
```

## Session Naming Conventions

**Good names:**
- `my-web-app`
- `user-auth-service`
- `analytics-dashboard`

**Bad names:**
- `MyWebApp` (avoid camelCase)
- `my_web_app` (avoid underscores)
- `app` (too generic)

## Project Path Guidelines

**Always use absolute paths:**
- Good: `/Users/username/projects/my-app`
- Good: `~/projects/my-app`
- Bad: `./my-app` (relative)
- Bad: `my-app` (relative)

**Common patterns:**
- Personal projects: `~/projects/[project-name]`
- Work projects: `~/work/[project-name]`
- Client projects: `~/clients/[client-name]/[project-name]`

## Tmux Attach Options

```bash
# Basic attach
tmux attach-session -t SESSION_NAME

# Attach with detach others
tmux attach-session -dt SESSION_NAME

# Attach read-only
tmux attach-session -rt SESSION_NAME
```

## Troubleshooting

### Session Already Exists

**Error:** "duplicate session: [name]"

**Solution:**
```bash
# List existing sessions
tmux list-sessions

# Kill the existing session
tmux kill-session -t SESSION_NAME

# Or attach to existing
tmux attach-session -t SESSION_NAME
```

### Project Path Doesn't Exist

**Error:** Directory not found

**Solution:**
```bash
# Create the directory first
mkdir -p /path/to/project

# Then run deploy-pm
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm SESSION_NAME -p /path/to/project
```

### Orchestrator Not Found

**Error:** No such file or directory

**Solution:**
```bash
# Verify orchestrator path
ls -la ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py

# Update path if different
export YATO_PATH="/path/to/yato"
uv run --directory $YATO_PATH python $YATO_PATH/lib/orchestrator.py deploy-pm SESSION_NAME -p PROJECT_PATH
```

## Integration with Other Tools

### Git Repository Initialization

After creating the session, you may want to initialize git:

```bash
tmux send-keys -t SESSION_NAME:0 "git init" Enter
tmux send-keys -t SESSION_NAME:0 "git add ." Enter
tmux send-keys -t SESSION_NAME:0 "git commit -m 'Initial commit'" Enter
```

### Adding Team Members

To add developers to the project:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/create-agent.sh SESSION_NAME developer \
  -p PROJECT_PATH \
  --pm-window SESSION_NAME:0
```

## Best Practices

1. **Choose descriptive session names** that indicate the project purpose
2. **Use consistent project paths** within a projects directory
3. **Document the session** in your notes or project wiki
4. **Attach frequently** to monitor PM progress
5. **Schedule check-ins** with the PM using schedule-checkin.sh
