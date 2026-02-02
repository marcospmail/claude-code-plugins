#!/bin/bash
# restart-checkin-display.sh - Restart the check-in display in pane 0
# Usage: ./restart-checkin-display.sh [session:window]
#
# If no target specified, auto-detects from current tmux session

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect target
if [[ -n "$1" ]]; then
    TARGET="$1.0"  # Add pane 0
else
    SESSION=$(tmux display-message -p '#S' 2>/dev/null)
    if [[ -z "$SESSION" ]]; then
        echo "Error: Not in tmux and no target specified"
        echo "Usage: $0 [session:window]"
        exit 1
    fi
    TARGET="$SESSION:0.0"
fi

echo "Restarting check-in display in $TARGET..."

# Kill any existing checkin-display process in the pane
tmux send-keys -t "$TARGET" C-c
sleep 0.3

# Clear the pane
tmux send-keys -t "$TARGET" "clear" Enter
sleep 0.2

# Start the display script
DISPLAY_SCRIPT="$SCRIPT_DIR/checkin-display.sh"
tmux send-keys -t "$TARGET" "bash $DISPLAY_SCRIPT" Enter

echo "Check-in display restarted in $TARGET"
