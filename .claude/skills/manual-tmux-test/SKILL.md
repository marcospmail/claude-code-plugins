---
name: manual-tmux-test
description: Manual testing instructions for Yato workflows via tmux. Use this skill whenever you need to test Yato workflow execution, verify agent behavior, or validate task completion in tmux sessions.
allowed-tools: Bash, Read, Glob
user-invocable: false
---

# Manual Tmux Test

<context>
This skill provides comprehensive instructions for manually testing Yato workflows via tmux. It covers three primary test scenarios: new projects, existing projects, and workflow resume functionality. Use this for end-to-end validation of the Yato orchestration system.
</context>

<instructions>
## Prerequisites

Before starting any test, set the YATO_PATH variable:

```bash
YATO_PATH="$HOME/dev/tools/yato"
```

Ensure Yato is properly installed and the plugin is loaded in Claude Code.

## Test Scenario 1: New Project Test

### Setup
1. Create a test directory in /tmp:
```bash
mkdir -p /tmp/yato-test-new-project
cd /tmp/yato-test-new-project
```

2. Initialize as git repository (required for workflows):
```bash
git init
git config user.name "Test User"
git config user.email "test@example.com"
```

### Execution
3. Trigger the yato-new-project skill:
```bash
# In Claude Code, use the skill or manually invoke:
# "Create a new project for [description]"
```

4. Monitor tmux session creation:
```bash
# List all tmux sessions
tmux list-sessions

# List windows in the test session
tmux list-windows -t yato-test-new-project
```

Expected windows:
- Window 0: PM agent
- Window 1+: Developer/QA agents

### Monitoring PM Pane
5. Capture PM pane output:
```bash
# Capture PM pane (usually window 0, pane 0)
tmux capture-pane -t yato-test-new-project:0.0 -p | tail -50

# Watch PM pane in real-time (optional)
tmux attach-session -t yato-test-new-project -r
```

6. Monitor checkin display pane:
```bash
# Capture checkin display (usually window 0, pane 1)
tmux capture-pane -t yato-test-new-project:0.1 -p | tail -30
```

### Monitoring Developer Panes
7. Check developer agent status:
```bash
# Capture developer pane (usually window 1)
tmux capture-pane -t yato-test-new-project:1 -p | tail -50
```

### Verification Steps

8. Verify workflow directory structure:
```bash
# Check .workflow directory exists
ls -la /tmp/yato-test-new-project/.workflow/

# Check current workflow is set
cat /tmp/yato-test-new-project/.workflow/current

# Check workflow status
cat /tmp/yato-test-new-project/.workflow/*/status.yml
```

Expected status.yml:
```yaml
status: in-progress  # Initially
title: "[Project Title]"
initial_request: |
  [User's original request]
folder: "001-[project-name]"
checkin_interval_minutes: 15
session: "yato-test-new-project"
```

9. Verify PRD creation:
```bash
# Read the PRD
cat /tmp/yato-test-new-project/.workflow/*/prd.md
```

Expected: Detailed product requirements document.

10. Verify team.yml creation:
```bash
# Read team structure
cat /tmp/yato-test-new-project/.workflow/*/team.yml
```

Expected format:
```yaml
agents:
  - name: developer
    role: developer
    model: sonnet
  - name: qa
    role: qa
    model: sonnet
```

11. Verify tasks.json creation:
```bash
# Read tasks
cat /tmp/yato-test-new-project/.workflow/*/tasks.json
```

Expected format:
```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Task description",
      "description": "Details...",
      "activeForm": "Doing task",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
```

12. Verify agents.yml runtime registry:
```bash
# Read runtime agent registry
cat /tmp/yato-test-new-project/.workflow/*/agents.yml
```

Expected: List of created agents with their tmux targets.

13. Monitor task completion:
```bash
# Watch tasks.json for status changes
watch -n 5 "cat /tmp/yato-test-new-project/.workflow/*/tasks.json | grep -A 2 'status'"
```

14. Verify tasks progress to "completed":
```bash
# Check all tasks are completed
cat /tmp/yato-test-new-project/.workflow/*/tasks.json | grep '"status"'
```

Expected: All tasks should have `"status": "completed"`

15. Verify final status.yml:
```bash
cat /tmp/yato-test-new-project/.workflow/*/status.yml
```

Expected: `status: completed`

### Cleanup
16. Kill the test session:
```bash
tmux kill-session -t yato-test-new-project
```

17. Remove test directory (optional):
```bash
rm -rf /tmp/yato-test-new-project
```

## Test Scenario 2: Existing Project Test

### Setup
1. Create a simple test project in /tmp:
```bash
mkdir -p /tmp/yato-test-existing-project
cd /tmp/yato-test-existing-project
git init
git config user.name "Test User"
git config user.email "test@example.com"
```

2. Add sample files:
```bash
# Create a simple HTML/CSS/JS project
cat > index.html <<'EOF'
<!DOCTYPE html>
<html>
<head>
    <title>Test App</title>
    <link rel="stylesheet" href="styles.css">
</head>
<body>
    <h1>Hello World</h1>
    <script src="app.js"></script>
</body>
</html>
EOF

cat > styles.css <<'EOF'
body {
    font-family: Arial, sans-serif;
    margin: 20px;
}
EOF

cat > app.js <<'EOF'
console.log('Hello from app.js');
EOF

# Commit the initial state
git add .
git commit -m "Initial commit"
```

### Execution
3. Trigger yato-existing-project skill:
```bash
# In Claude Code, use the skill:
# "Add a dark mode toggle button to this project"
```

4. Monitor session creation:
```bash
tmux list-sessions
tmux list-windows -t yato-test-existing-project
```

### Monitoring
5. Monitor PM analysis:
```bash
# Capture PM pane to see codebase analysis
tmux capture-pane -t yato-test-existing-project:0.0 -p | tail -100
```

Expected: PM should analyze existing files and understand project structure.

6. Monitor checkin display:
```bash
tmux capture-pane -t yato-test-existing-project:0.1 -p | tail -30
```

7. Monitor developer work:
```bash
# Watch developer agent
tmux capture-pane -t yato-test-existing-project:1 -p | tail -50
```

### Verification Steps
8. Verify workflow files created:
```bash
ls -la /tmp/yato-test-existing-project/.workflow/
cat /tmp/yato-test-existing-project/.workflow/*/prd.md
cat /tmp/yato-test-existing-project/.workflow/*/team.yml
cat /tmp/yato-test-existing-project/.workflow/*/tasks.json
```

9. Monitor task progress:
```bash
# Watch for task completion
watch -n 5 "cat /tmp/yato-test-existing-project/.workflow/*/tasks.json | grep 'status'"
```

10. Verify code changes:
```bash
# Check git status for changes
cd /tmp/yato-test-existing-project
git status
git diff
```

Expected: Modified files implementing the requested feature.

11. Verify all tasks completed:
```bash
cat /tmp/yato-test-existing-project/.workflow/*/tasks.json | grep '"status": "completed"' | wc -l
cat /tmp/yato-test-existing-project/.workflow/*/tasks.json | grep '"status":' | wc -l
# First count should equal second count
```

12. Check final workflow status:
```bash
cat /tmp/yato-test-existing-project/.workflow/*/status.yml
```

Expected: `status: completed`

### Cleanup
```bash
tmux kill-session -t yato-test-existing-project
rm -rf /tmp/yato-test-existing-project
```

## Test Scenario 3: Resume Workflow Test

### Setup
1. Start with a workflow in progress (use Scenario 1 or 2):
```bash
# Assume yato-test-new-project is running
tmux list-sessions
```

2. Let the workflow run for a few minutes, then intentionally kill the session:
```bash
# Kill the tmux session (simulating a crash or disconnect)
tmux kill-session -t yato-test-new-project
```

3. Verify session is gone:
```bash
tmux list-sessions | grep yato-test-new-project
# Should return nothing
```

### Resume Execution
4. Run the resume script:
```bash
cd /tmp/yato-test-new-project
$YATO_PATH/bin/resume-workflow.sh
```

5. Verify session restored:
```bash
tmux list-sessions
tmux list-windows -t yato-test-new-project
```

### Verification Steps
6. Verify PM pane has Claude running:
```bash
# Capture PM pane
tmux capture-pane -t yato-test-new-project:0.0 -p | tail -50
```

Expected: Claude Code prompt should be visible, not shell prompt.

7. Verify checkin-display is running:
```bash
# Capture checkin display pane
tmux capture-pane -t yato-test-new-project:0.1 -p | tail -30
```

Expected: Should show checkin schedule or "No check-ins scheduled"

8. Verify agent panes restored:
```bash
# Check each agent window
tmux list-windows -t yato-test-new-project

# Capture each agent pane
tmux capture-pane -t yato-test-new-project:1 -p | tail -50
```

Expected: Each agent should have Claude Code running.

9. Verify workflow state preserved:
```bash
# Read workflow files
cat /tmp/yato-test-new-project/.workflow/*/status.yml
cat /tmp/yato-test-new-project/.workflow/*/tasks.json
cat /tmp/yato-test-new-project/.workflow/*/agents.yml
```

Expected: All files should be intact with current progress.

10. Verify agents can continue work:
```bash
# Send a test message to PM
$YATO_PATH/bin/send-message.sh yato-test-new-project:0 "Status update?"

# Wait and capture response
sleep 5
tmux capture-pane -t yato-test-new-project:0.0 -p | tail -30
```

Expected: PM should respond to the message.

11. Monitor continued progress:
```bash
# Watch tasks.json for changes
watch -n 10 "cat /tmp/yato-test-new-project/.workflow/*/tasks.json | grep 'status'"
```

Expected: Tasks should continue progressing to completion.

12. Verify registry consistency:
```bash
# Check Yato registry
cat $HOME/.yato/registry.json | jq '.agents[] | select(.session_name == "yato-test-new-project")'
```

Expected: All agents should be registered with correct windows.

### Cleanup
```bash
tmux kill-session -t yato-test-new-project
rm -rf /tmp/yato-test-new-project
```

## General Monitoring Commands

### Tmux State Inspection
```bash
# List all sessions
tmux list-sessions

# List windows in a session
tmux list-windows -t <session>

# List panes in a window
tmux list-panes -t <session>:<window>

# Capture specific pane
tmux capture-pane -t <session>:<window>.<pane> -p | tail -N

# Attach to session (read-only)
tmux attach-session -t <session> -r
```

### Workflow File Inspection
```bash
# Check current workflow
cat <project>/.workflow/current

# Read workflow status
cat <project>/.workflow/*/status.yml

# Read PRD
cat <project>/.workflow/*/prd.md

# Read team structure
cat <project>/.workflow/*/team.yml

# Read tasks
cat <project>/.workflow/*/tasks.json | jq '.'

# Read agent registry
cat <project>/.workflow/*/agents.yml
```

### Yato Registry Inspection
```bash
# View all agents
cat $HOME/.yato/registry.json | jq '.agents'

# View specific session agents
cat $HOME/.yato/registry.json | jq '.agents[] | select(.session_name == "<session>")'

# View checkins
cat $HOME/.yato/checkins.json | jq '.checkins'

# View pending checkins
cat $HOME/.yato/checkins.json | jq '.checkins[] | select(.status == "pending")'
```

### Agent Communication Testing
```bash
# Send message to PM
$YATO_PATH/bin/send-message.sh <session>:0 "Test message"

# Send message to developer
$YATO_PATH/bin/send-message.sh <session>:1 "Test message"

# Verify message received (wait 2-3 seconds)
sleep 3
tmux capture-pane -t <session>:<window> -p | tail -30
```

## Success Criteria

### New Project Test Success
- [ ] Tmux session created with PM and agent windows
- [ ] .workflow/ directory created with correct structure
- [ ] status.yml contains initial request and metadata
- [ ] prd.md created with detailed requirements
- [ ] team.yml created with agent definitions
- [ ] tasks.json created with all tasks assigned to agents
- [ ] agents.yml created with runtime agent mappings
- [ ] All agents visible in tmux windows
- [ ] Tasks progress from "pending" to "in-progress" to "completed"
- [ ] Final status.yml shows `status: completed`
- [ ] Checkin display shows scheduled check-ins

### Existing Project Test Success
- [ ] PM analyzes existing codebase correctly
- [ ] PRD reflects understanding of current code
- [ ] Tasks are appropriate for the existing project structure
- [ ] Code changes are made to existing files
- [ ] Git shows modified files (not new unrelated files)
- [ ] All tasks complete successfully
- [ ] Final workflow status is "completed"

### Resume Workflow Test Success
- [ ] Tmux session is killed and verified absent
- [ ] Resume script recreates the session
- [ ] All windows and panes are restored
- [ ] PM pane shows Claude Code running (not shell)
- [ ] Checkin display is running
- [ ] Agent panes show Claude Code running
- [ ] Workflow files (status.yml, tasks.json) are intact
- [ ] Agents respond to messages after resume
- [ ] Tasks continue progressing
- [ ] Yato registry matches tmux state

## Troubleshooting

### Session Not Created
```bash
# Check for errors in orchestrator
python3 $YATO_PATH/lib/orchestrator.py status

# Check tmux server is running
tmux info
```

### PM Not Responding
```bash
# Check if Claude is running in PM pane
tmux capture-pane -t <session>:0.0 -p | tail -5

# If shell prompt visible, Claude crashed - check logs
# Restart PM manually:
tmux send-keys -t <session>:0.0 "claude code" Enter
```

### Tasks Not Progressing
```bash
# Check developer agent output
tmux capture-pane -t <session>:1 -p | tail -100

# Send manual status request to PM
$YATO_PATH/bin/send-message.sh <session>:0 "What is the current status?"

# Check for blocked tasks
cat <project>/.workflow/*/tasks.json | jq '.tasks[] | select(.blockedBy != [])'
```

### Resume Script Fails
```bash
# Check if .workflow/ directory exists
ls -la <project>/.workflow/

# Check if status.yml has session name
cat <project>/.workflow/*/status.yml | grep session

# Manually verify agents.yml
cat <project>/.workflow/*/agents.yml
```

### Checkin Display Not Showing
```bash
# Check if pane 1 exists in window 0
tmux list-panes -t <session>:0

# Check if checkin script is running
ps aux | grep checkin-display

# Restart checkin display manually
tmux send-keys -t <session>:0.1 "$YATO_PATH/bin/checkin-display.sh" Enter
```
</instructions>
