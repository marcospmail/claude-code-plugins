#!/bin/bash
# init-workflow.sh - Create a new numbered workflow folder
#
# Usage: ./init-workflow.sh <project-path> "<title>"
#
# Creates a workflow folder like: .workflow/001-add-user-auth/
# Note: session name in status.yml is set later by orchestrator.py deploy_pm_only

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

# Support isolated tmux socket (used by e2e tests)
TMUX_FLAGS="${TMUX_SOCKET:+-L $TMUX_SOCKET}"

# Set WORKFLOW_NAME in tmux environment, scoped to the current session (if in tmux)
if [[ -n "$TMUX" ]]; then
    _INIT_SESSION=$(tmux $TMUX_FLAGS display-message -p '#S' 2>/dev/null || echo "")
    [[ -n "$_INIT_SESSION" ]] && tmux $TMUX_FLAGS setenv -t "$_INIT_SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"
fi

# NOTE: We intentionally do NOT create .workflow/current file
# Multiple workflows can run simultaneously in different tmux sessions
# Each session has its own WORKFLOW_NAME env var - there is no single "current" workflow

# Create PM agent files (identity.yml, instructions.md, constraints.md, CLAUDE.md, etc.)
_YATO_WORKFLOW_NAME="$WORKFLOW_NAME" bash "$SCRIPT_DIR/init-agent-files.sh" "$PROJECT_PATH" "pm" "pm" "opus"

# Add initial_request to status.yml if it exists at root level
INITIAL_REQUEST_FILE="$PROJECT_PATH/.workflow/initial-request.md"
if [[ -f "$INITIAL_REQUEST_FILE" ]]; then
    # Read content and escape for YAML (use literal block style)
    INITIAL_REQUEST_CONTENT=$(cat "$INITIAL_REQUEST_FILE")

    # Create temp file with updated status.yml
    uv run python -c "
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

# NOTE: We do NOT write the session name here. init-workflow.sh runs in the
# INVOKING session (e.g. the user's current session), not the workflow session.
# The correct session name is set later by orchestrator.py deploy_pm_only,
# which creates the actual workflow tmux session.

# Get session for agents.yml (best-effort, orchestrator will correct it)
SESSION=$(tmux $TMUX_FLAGS display-message -p '#S' 2>/dev/null || echo "")

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
echo "  └── agents.yml (agent registry with PM + team locations)"
echo ""
echo "Files to create:"
echo "  - prd.md       (Product Requirements Document)"
echo "  - tasks.json   (Task tracking - JSON format)"
