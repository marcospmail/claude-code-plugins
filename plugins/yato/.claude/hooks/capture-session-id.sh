#!/bin/bash
# Capture session_id when Claude starts and write to agent's identity.yml
# This runs for ALL agents (PM, developer, QA, etc.)

# Read session_id from JSON stdin
SESSION_DATA=$(cat)
SESSION_ID=$(echo "$SESSION_DATA" | uv run python -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

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
