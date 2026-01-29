#!/bin/bash
# notify-pm.sh - Send message to PM
# PM is always at window 0, pane 1 (pane 0 is check-ins display)
#
# Usage: notify-pm.sh "[DONE] Task completed"
# Usage: notify-pm.sh "[BLOCKED] Need help with X"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <message>"
    echo "Example: $0 '[DONE] Task completed'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Auto-detect current session
SESSION=$(tmux display-message -p '#S' 2>/dev/null)
if [[ -z "$SESSION" ]]; then
    echo "Error: Not running in a tmux session"
    exit 1
fi

# PM is always at window 0, pane 1
PM_TARGET="$SESSION:0.1"

# Send message to PM using send-message.sh
"$SCRIPT_DIR/send-message.sh" "$PM_TARGET" "$*"
