---
name: yato-cleanup
description: Clean up a Yato workflow session. Kills agents, tmux sessions, check-in daemons, and marks the workflow as completed. Optionally deletes the workflow folder. Use when you want to tear down a running Yato session.
allowed-tools: Bash,Read,AskUserQuestion
user-invocable: true
disable-model-invocation: false
argument-hint: "[workflow-name or leave empty for current]"
---

# Yato Cleanup

<context>
This skill tears down a running Yato workflow session. It stops all agents, kills the tmux session, stops the check-in daemon, and marks the workflow as completed.

Use this when:
- You're done with a workflow and want to clean everything up
- You want to stop all agents and free resources
- A workflow is stuck and you want to start fresh
</context>

<capabilities>
- Detects the current or specified workflow
- Lists workflows if no argument and multiple exist
- Kills the check-in daemon (if running)
- Kills the tmux session (all agent windows/panes)
- Marks workflow status as completed in status.yml
- Optionally deletes the workflow folder
</capabilities>

<requirements>
- Yato installed at ${CLAUDE_PLUGIN_ROOT}
- A project with existing .workflow/ folder
- Current directory should be the project root
</requirements>

<instructions>
## Step 1: Detect Project and Workflow

```bash
PROJECT_PATH=$(pwd)
```

Check if .workflow directory exists:
```bash
if [[ ! -d "$PROJECT_PATH/.workflow" ]]; then
    echo "No workflows found in this project."
    exit 1
fi
```

## Step 2: Determine Which Workflow to Clean Up

If `$ARGUMENTS` is provided, use it as the workflow name.

If `$ARGUMENTS` is empty, list workflows and let user pick:

```bash
ls -d "$PROJECT_PATH/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | while read dir; do
    wf_name=$(basename "$dir")
    status=$(grep "^status:" "$dir/status.yml" 2>/dev/null | sed 's/status: //')
    session=$(grep "^session:" "$dir/status.yml" 2>/dev/null | sed 's/session: //' | tr -d '"' | tr -d "'")
    echo "$wf_name [$status] (session: $session)"
done
```

If only one in-progress workflow exists, use it automatically.
If multiple exist, use AskUserQuestion to let the user pick which one.

Set `WORKFLOW_NAME` to the chosen workflow folder name (e.g., "001-add-feature").

## Step 3: Read Workflow Info

```bash
WORKFLOW_PATH="$PROJECT_PATH/.workflow/$WORKFLOW_NAME"
```

Read status.yml to get the session name:
```bash
SESSION=$(grep "^session:" "$WORKFLOW_PATH/status.yml" 2>/dev/null | sed 's/session: //' | tr -d '"' | tr -d "'" | xargs)
```

## Step 4: Kill Check-in Daemon

Read the daemon PID from checkins.json and kill it:
```bash
if [[ -f "$WORKFLOW_PATH/checkins.json" ]]; then
    DAEMON_PID=$(python3 -c "import json; data=json.load(open('$WORKFLOW_PATH/checkins.json')); print(data.get('daemon_pid') or '')" 2>/dev/null)
    if [[ -n "$DAEMON_PID" ]]; then
        kill "$DAEMON_PID" 2>/dev/null
        sleep 1
        kill -9 "$DAEMON_PID" 2>/dev/null
        echo "Killed check-in daemon (PID: $DAEMON_PID)"
    fi
fi
```

## Step 5: Kill Tmux Session

Kill the tmux session which destroys all agent windows and panes:
```bash
if [[ -n "$SESSION" && "$SESSION" != "_" ]]; then
    tmux kill-session -t "$SESSION" 2>/dev/null && echo "Killed tmux session: $SESSION" || echo "Session '$SESSION' was not running"
fi
```

## Step 6: Update Workflow Status

Mark the workflow as completed and cancel pending check-ins:
```bash
# Update status.yml
cd ${CLAUDE_PLUGIN_ROOT} && uv run python -c "
import yaml, re, json
from datetime import datetime
from pathlib import Path

workflow_path = Path('$WORKFLOW_PATH')
now = datetime.now().isoformat()

# Update status.yml
status_file = workflow_path / 'status.yml'
if status_file.exists():
    content = status_file.read_text()
    content = re.sub(r'^status:.*$', 'status: completed', content, flags=re.MULTILINE)
    if 'completed_at:' not in content:
        content = content.rstrip() + '\ncompleted_at: ' + now + '\n'
    status_file.write_text(content)
    print('Updated status.yml -> completed')

# Clean up checkins.json
checkins_file = workflow_path / 'checkins.json'
if checkins_file.exists():
    data = json.loads(checkins_file.read_text())
    data['daemon_pid'] = None
    for c in data.get('checkins', []):
        if c.get('status') == 'pending':
            c['status'] = 'cancelled'
            c['cancelled_at'] = now
    data.setdefault('checkins', []).append({
        'id': f'cleanup-{int(datetime.fromisoformat(now).timestamp())}',
        'status': 'cleanup',
        'note': 'Manual cleanup via /yato-cleanup',
        'created_at': now,
    })
    checkins_file.write_text(json.dumps(data, indent=2))
    print('Cleaned up checkins.json')
"
```

## Step 7: Ask About Workflow Folder Deletion

Use AskUserQuestion to ask:

**Question:** "Do you want to delete the workflow folder (.workflow/$WORKFLOW_NAME)?"
**Header:** "Cleanup"
**Options:**
1. **Label:** "Keep" — **Description:** "Keep the workflow folder for reference/history"
2. **Label:** "Delete" — **Description:** "Permanently delete the workflow folder and all agent files"

If user selects "Delete":
```bash
rm -rf "$WORKFLOW_PATH"
echo "Deleted workflow folder: $WORKFLOW_PATH"
```

If user selects "Keep":
```
Workflow folder kept at: .workflow/$WORKFLOW_NAME
```

## Step 8: Summary Output

Output a summary of what was cleaned up.
</instructions>

<examples>
<example>
<scenario>User runs /yato-cleanup with one active workflow</scenario>
<action>
1. PROJECT_PATH = /Users/user/projects/my-app
2. Find single in-progress workflow: 001-add-auth
3. SESSION = "my-app_001-add-auth"
4. Kill daemon PID 12345
5. Kill tmux session "my-app_001-add-auth"
6. Update status.yml -> completed
7. Ask about folder deletion -> user keeps
8. Output summary
</action>
</example>

<example>
<scenario>User runs /yato-cleanup 002-fix-bug</scenario>
<action>
1. PROJECT_PATH = current directory
2. WORKFLOW_NAME = "002-fix-bug" (from argument)
3. Read session from status.yml
4. Kill daemon, kill session
5. Update status, ask about deletion
6. Output summary
</action>
</example>

<example>
<scenario>User runs /yato-cleanup with no workflows</scenario>
<action>
1. Check .workflow directory doesn't exist
2. Output: "No workflows found in this project."
</action>
</example>
</examples>

<output_format>
**Cleanup complete:**

| Step | Status |
|------|--------|
| Check-in daemon | Killed (PID: 12345) |
| Tmux session | Killed (my-app_001-add-auth) |
| Workflow status | Marked as completed |
| Workflow folder | Kept / Deleted |
</output_format>
