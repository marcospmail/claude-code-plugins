#!/bin/bash
# cancel-checkin.sh - Cancel the check-in daemon
# Usage: ./cancel-checkin.sh
#
# This is a wrapper around the Python checkin_scheduler module.
# It kills the running daemon process directly via its PID and
# marks check-ins as cancelled in checkins.json.
#
# Reads WORKFLOW_NAME from tmux environment variable.
# Daemon PID is stored in .workflow/$WORKFLOW_NAME/checkins.json["daemon_pid"]

# Get script directory for finding the Python module
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YATO_PATH="$(dirname "$SCRIPT_DIR")"

# Get workflow name from tmux environment variable
CURRENT_WORKFLOW=""
if [[ -n "$TMUX" ]]; then
    CURRENT_WORKFLOW=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
fi

# Execute the Python module's cancel command
if [[ -n "$CURRENT_WORKFLOW" ]]; then
    python3 "$YATO_PATH/lib/checkin_scheduler.py" cancel --workflow "$CURRENT_WORKFLOW"
else
    python3 "$YATO_PATH/lib/checkin_scheduler.py" cancel
fi
