#!/bin/bash
# Block cancel-checkin.sh for ALL agents (PM, Developer, QA, etc.)
# The check-in loop stops AUTOMATICALLY when all tasks complete
# Only the USER can cancel it manually via /cancel-checkin skill

# Read JSON input
INPUT=$(cat)

# Check if command contains cancel-checkin.sh
COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

# If not a cancel-checkin command, allow it
if [[ "$COMMAND" != *"cancel-checkin"* ]]; then
    exit 0
fi

# Get current session_id
CURRENT_SESSION_ID=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('session_id',''))" 2>/dev/null)

if [ -z "$CURRENT_SESSION_ID" ]; then
    exit 0  # No session_id available, allow (likely user)
fi

# Find the active workflow directory
WORKFLOW_DIR=$(ls -td .workflow/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
if [ -z "$WORKFLOW_DIR" ]; then
    exit 0  # No workflow, allow
fi

# Check if current session matches ANY agent's session_id
AGENTS_DIR="${WORKFLOW_DIR}agents"
if [ ! -d "$AGENTS_DIR" ]; then
    exit 0  # No agents directory, allow
fi

# Loop through all agent identity files
for IDENTITY_FILE in "$AGENTS_DIR"/*/identity.yml; do
    [ -f "$IDENTITY_FILE" ] || continue

    AGENT_SESSION_ID=$(grep "^session_id:" "$IDENTITY_FILE" 2>/dev/null | awk '{print $2}')
    AGENT_NAME=$(grep "^name:" "$IDENTITY_FILE" 2>/dev/null | awk '{print $2}')

    # Block if current session matches this agent's session
    if [ -n "$AGENT_SESSION_ID" ] && [ "$CURRENT_SESSION_ID" = "$AGENT_SESSION_ID" ]; then
        cat >&2 << ERRMSG
BLOCKED: ${AGENT_NAME:-Agent} cannot call cancel-checkin.sh

The check-in loop stops AUTOMATICALLY when all tasks in tasks.json are completed.
You do NOT need to cancel it manually.

Focus on your assigned tasks. The system will handle check-in scheduling.

Only the USER can stop the loop early via /cancel-checkin if they choose to.
ERRMSG
        exit 2
    fi
done

# No matching agent found - allow (this is the user)
exit 0
