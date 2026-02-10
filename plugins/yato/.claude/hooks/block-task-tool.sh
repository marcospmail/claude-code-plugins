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
  ${CLAUDE_PLUGIN_ROOT}/bin/create-team.sh PROJECT_PATH name:role:model

Examples:
  create-team.sh /path developer:developer:opus
  create-team.sh /path impl:developer:sonnet tester:qa:sonnet

Then use send-message.sh to communicate with agents.
ERRMSG
    exit 2
fi

# Allow for other agents
exit 0
