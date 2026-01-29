#!/bin/bash
# init-workflow.sh - Create a new numbered workflow folder
#
# Usage: ./init-workflow.sh <project-path> "<title>"
#
# Creates a workflow folder like: .workflow/001-add-user-auth/
# Updates status.yml with session info if in tmux

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
source "$SCRIPT_DIR/workflow-utils.sh"

# Parse arguments
PROJECT_PATH="${1:-$(pwd)}"
TITLE="${2:-}"

if [[ -z "$TITLE" ]]; then
    echo "Usage: init-workflow.sh <project-path> \"<title>\""
    echo ""
    echo "Example:"
    echo "  init-workflow.sh ~/projects/myapp \"Add user authentication\""
    exit 1
fi

# Expand project path
PROJECT_PATH=$(eval echo "$PROJECT_PATH")

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Creating project directory: $PROJECT_PATH"
    mkdir -p "$PROJECT_PATH"
fi

# Create workflow folder
WORKFLOW_NAME=$(create_workflow_folder "$PROJECT_PATH" "$TITLE")
WORKFLOW_PATH="$PROJECT_PATH/.workflow/$WORKFLOW_NAME"

# Set WORKFLOW_NAME in tmux environment (if in tmux)
# This replaces the old .workflow/current file approach
if [[ -n "$TMUX" ]]; then
    tmux setenv WORKFLOW_NAME "$WORKFLOW_NAME"
fi

# Create PM instructions.md
cat > "$WORKFLOW_PATH/agents/pm/instructions.md" <<'EOF'
# PM INSTRUCTIONS - MUST FOLLOW

## WHEN USER SAYS "continue"

Your FIRST and ONLY action must be to delegate the next pending task.

Run this bash command:
```bash
SESSION=$(tmux display-message -p '#S') && ~/dev/tools/yato/bin/send-message.sh "$SESSION:WINDOW" "TASK_DESCRIPTION"
```

Replace WINDOW and TASK_DESCRIPTION:
- **WINDOW**: Get from agents.yml (e.g., for "qa" agent, window is "1")
- **TASK_DESCRIPTION**: The task details from tasks.json

Then say: "Delegated [task] to [agent name] at window [window]"

## FORBIDDEN - YOU WILL FAIL IF YOU DO THESE

- DO NOT run mcp-cli commands
- DO NOT use browser automation tools
- DO NOT write or modify code
- DO NOT run tests
- DO NOT do ANY implementation work yourself

These tools are for AGENTS, not for you. You only DELEGATE.

## AFTER READING FILES

1. Report what tasks are pending (from tasks.json)
2. Report which agent handles each task (from agents.yml - shows agent windows)
3. Wait for user to say "continue"

## YOUR ROLE

You are the PM. You COORDINATE and DELEGATE. You do NOT implement.

When you see "continue":
1. Run the send-message.sh command above
2. Report that you delegated
3. Do NOTHING else
EOF

# Create PM identity.yml
cat > "$WORKFLOW_PATH/agents/pm/identity.yml" <<EOF
name: PM
role: pm
agent_id: pending
can_modify_code: false
model: opus
pm_window: none
agents_registry: ../../agents.yml
instructions: ./instructions.md
constraints: ./constraints.md
created_at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")
EOF

# Create PM constraints.example.md
cat > "$WORKFLOW_PATH/agents/pm/constraints.example.md" <<'EOF'
# PM Constraints (Example)
# Copy this file to constraints.md and customize for your project

## Forbidden Actions
- Do NOT write implementation code
- Do NOT run tests directly (delegate to QA agent)
- Do NOT make git commits (delegate to agents)

## Required Actions
- ALWAYS delegate implementation to agents
- ALWAYS update tasks.json when tasks change status
- ALWAYS provide specific, actionable feedback

## Communication Rules
- Keep messages concise and actionable
- Include acceptance criteria in task assignments
- Respond to agent check-ins promptly
EOF

# Create project-level hooks for orchestrator workflow
mkdir -p "$PROJECT_PATH/.claude/hooks"

# Create settings.json with SessionStart and PreToolUse hooks
cat > "$PROJECT_PATH/.claude/settings.json" <<'EOF'
{
  "hooks": {
    "SessionStart": [
      {
        "matcher": "",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/capture-session-id.sh"
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Task",
        "hooks": [
          {
            "type": "command",
            "command": "bash .claude/hooks/block-task-tool.sh"
          }
        ]
      }
    ]
  }
}
EOF

# Create SessionStart hook to capture session_id for all agents
cat > "$PROJECT_PATH/.claude/hooks/capture-session-id.sh" <<'EOF'
#!/bin/bash
# Capture session_id when Claude starts and write to agent's identity.yml
# This runs for ALL agents (PM, developer, QA, etc.)

# Read session_id from JSON stdin
SESSION_DATA=$(cat)
SESSION_ID=$(echo "$SESSION_DATA" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

if [ -z "$SESSION_ID" ]; then
    exit 0  # No session_id, nothing to do
fi

# Get pane title to identify which agent this is
PANE_TITLE=""
if [ -n "$TMUX_PANE" ]; then
    PANE_TITLE=$(tmux display-message -t "$TMUX_PANE" -p '#{pane_title}' 2>/dev/null)
elif [ -n "$TMUX" ]; then
    PANE_TITLE=$(tmux display-message -p '#{pane_title}' 2>/dev/null)
fi

# Find the active workflow directory
WORKFLOW_DIR=$(ls -td .workflow/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
if [ -z "$WORKFLOW_DIR" ]; then
    exit 0  # No workflow, nothing to do
fi

# Map pane title to agent identity file
IDENTITY_FILE=""
case "$PANE_TITLE" in
    "PM")
        IDENTITY_FILE="${WORKFLOW_DIR}agents/pm/identity.yml"
        ;;
    "Check-ins"*|"")
        # Skip check-in pane or empty title
        exit 0
        ;;
    *)
        # For other agents, use pane title as folder name (lowercase)
        AGENT_NAME=$(echo "$PANE_TITLE" | tr '[:upper:]' '[:lower:]' | tr ' ' '-')
        IDENTITY_FILE="${WORKFLOW_DIR}agents/${AGENT_NAME}/identity.yml"
        ;;
esac

# Write session_id to identity file if it exists
if [ -f "$IDENTITY_FILE" ]; then
    if grep -q "^session_id:" "$IDENTITY_FILE"; then
        # Update existing session_id
        sed -i '' "s/^session_id:.*/session_id: $SESSION_ID/" "$IDENTITY_FILE" 2>/dev/null || \
        sed -i "s/^session_id:.*/session_id: $SESSION_ID/" "$IDENTITY_FILE"
    else
        # Append session_id
        echo "session_id: $SESSION_ID" >> "$IDENTITY_FILE"
    fi
fi

exit 0
EOF
chmod +x "$PROJECT_PATH/.claude/hooks/capture-session-id.sh"

# Create PreToolUse hook to block Task tool ONLY for PM (using session_id comparison)
cat > "$PROJECT_PATH/.claude/hooks/block-task-tool.sh" <<'EOF'
#!/bin/bash
# Block Task tool ONLY for PM agent - other agents (developers, QA) are allowed
# Uses session_id comparison instead of pane title for reliability

# Read JSON input to get current session_id
INPUT=$(cat)
CURRENT_SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

if [ -z "$CURRENT_SESSION_ID" ]; then
    exit 0  # No session_id available, allow
fi

# Find the active workflow directory
WORKFLOW_DIR=$(ls -td .workflow/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
if [ -z "$WORKFLOW_DIR" ]; then
    exit 0  # No workflow, allow
fi

# Get PM's session_id from identity file
PM_IDENTITY="${WORKFLOW_DIR}agents/pm/identity.yml"
if [ ! -f "$PM_IDENTITY" ]; then
    exit 0  # No PM identity file, allow
fi

PM_SESSION_ID=$(grep "^session_id:" "$PM_IDENTITY" 2>/dev/null | awk '{print $2}')

# Block if current session matches PM's session
if [ -n "$PM_SESSION_ID" ] && [ "$CURRENT_SESSION_ID" = "$PM_SESSION_ID" ]; then
    cat >&2 << 'ERRMSG'
BLOCKED: PM cannot use Task tool to spawn sub-agents.

Instead, use create-team.sh to create agents:
  $HOME/dev/tools/yato/bin/create-team.sh PROJECT_PATH name:role:model

Examples:
  create-team.sh /path developer:developer:opus
  create-team.sh /path impl:developer:sonnet tester:qa:sonnet

Then use send-message.sh to communicate with agents.
ERRMSG
    exit 2
fi

# Allow for other agents
exit 0
EOF
chmod +x "$PROJECT_PATH/.claude/hooks/block-task-tool.sh"

# Add initial_request to status.yml if it exists at root level
INITIAL_REQUEST_FILE="$PROJECT_PATH/.workflow/initial-request.md"
if [[ -f "$INITIAL_REQUEST_FILE" ]]; then
    # Read content and escape for YAML (use literal block style)
    INITIAL_REQUEST_CONTENT=$(cat "$INITIAL_REQUEST_FILE")

    # Create temp file with updated status.yml
    python3 -c "
import sys
content = '''$INITIAL_REQUEST_CONTENT'''
# Indent for YAML literal block
indented = '\n'.join('  ' + line if line else '' for line in content.split('\n'))
with open('$WORKFLOW_PATH/status.yml', 'r') as f:
    yml = f.read()
yml = yml.replace('initial_request: \"\"', 'initial_request: |\n' + indented)
with open('$WORKFLOW_PATH/status.yml', 'w') as f:
    f.write(yml)
"
    # Remove the temp file
    rm "$INITIAL_REQUEST_FILE"
    echo "Added initial_request to status.yml"
fi

# Get session if in tmux and update status.yml directly
SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "")
if [[ -n "$SESSION" ]]; then
    sed -i '' "s/^session: .*/session: \"$SESSION\"/" "$WORKFLOW_PATH/status.yml"
fi

# Create agents.yml with PM entry (pass workflow path directly since we just created it)
create_agents_yml "$PROJECT_PATH" "${SESSION:-unknown}" "$WORKFLOW_PATH"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              WORKFLOW CREATED SUCCESSFULLY                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Workflow: $WORKFLOW_NAME"
echo "Path: $WORKFLOW_PATH"
echo "Title: $TITLE"
[[ -n "$SESSION" ]] && echo "Session: $SESSION"
echo ""
echo "Structure:"
echo "  $WORKFLOW_PATH/"
echo "  ├── status.yml (includes initial_request if provided)"
echo "  ├── agents.yml (agent registry with PM + team locations)"
echo "  └── agents/"
echo "      └── pm/"
echo "          ├── identity.yml"
echo "          ├── instructions.md"
echo "          └── constraints.example.md"
echo ""
echo "Files to create:"
echo "  - prd.md       (Product Requirements Document)"
echo "  - tasks.json   (Task tracking - JSON format)"
echo "  - agents/pm/constraints.md (Copy from example and customize)"
