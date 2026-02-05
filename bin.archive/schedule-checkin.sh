#!/bin/bash
# schedule-checkin.sh - Start the check-in daemon
# Usage: ./schedule-checkin.sh <minutes> "<note>" [target_window]
#
# This is a wrapper around the Python checkin_scheduler module.
# It starts a single long-running daemon process that:
# - Sends check-in messages at the specified interval
# - Auto-stops when all tasks are complete
# - Can be killed directly via its PID
#
# Reads WORKFLOW_NAME from tmux environment variable.
# Check-ins are stored in .workflow/$WORKFLOW_NAME/checkins.json
# Daemon PID is stored in checkins.json["daemon_pid"]

MINUTES=${1:-}
NOTE=${2:-"Standard check-in"}
TARGET=${3:-""}

# Get script directory for finding the Python module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YATO_PATH="$(dirname "$SCRIPT_DIR")"

# Find project root by walking up directories looking for .workflow/
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.workflow" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

# Get workflow name from tmux environment variable
CURRENT_WORKFLOW=""
if [[ -n "$TMUX" ]]; then
    CURRENT_WORKFLOW=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
fi

# Validate workflow
if [[ -z "$CURRENT_WORKFLOW" ]]; then
    echo "Error: No WORKFLOW_NAME set in tmux environment."
    echo "Run this from within a tmux session with an active workflow."
    exit 1
fi

# Find project root (allows running from subdirectories)
PROJECT_ROOT=$(find_project_root)
if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: Could not find .workflow/ directory."
    echo "Make sure you're in a project with an active workflow, or in one of its subdirectories."
    exit 1
fi

# Change to project root for relative paths
cd "$PROJECT_ROOT" || exit 1

if [[ ! -d ".workflow/$CURRENT_WORKFLOW" ]]; then
    echo "Error: Workflow directory not found: $PROJECT_ROOT/.workflow/$CURRENT_WORKFLOW"
    exit 1
fi

# Get session name for default target
SESSION_NAME=$(tmux display-message -p '#S' 2>/dev/null || echo "tmux-orc")
if [[ -z "$TARGET" ]]; then
    TARGET="${SESSION_NAME}:0.1"
fi

# Build the Python command
PYTHON_CMD="python3 $YATO_PATH/lib/checkin_scheduler.py start"

if [[ -n "$MINUTES" ]]; then
    PYTHON_CMD="$PYTHON_CMD $MINUTES"
fi

PYTHON_CMD="$PYTHON_CMD --note '$NOTE' --target '$TARGET' --workflow '$CURRENT_WORKFLOW'"

# Execute the Python module
eval "$PYTHON_CMD"
