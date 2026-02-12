#!/bin/bash

# Send message to Claude agent in tmux window
# Usage: send-claude-message.sh <session:window> <message>

# Support isolated tmux socket (used by e2e tests)
TMUX_FLAGS="${TMUX_SOCKET:+-L $TMUX_SOCKET}"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <session:window> <message>"
    echo "Example: $0 agentic-seek:3 'Hello Claude!'"
    exit 1
fi

WINDOW="$1"
shift  # Remove first argument, rest is the message
MESSAGE="$*"

# Default to pane 0 if no pane specified
if [[ "$WINDOW" != *.* ]]; then
    WINDOW="${WINDOW}.0"
fi

# First select the target pane to ensure it's active
tmux $TMUX_FLAGS select-pane -t "$WINDOW" 2>/dev/null || true

# Exit copy mode if active (prevents search mode trigger from / in paths)
tmux $TMUX_FLAGS send-keys -t "$WINDOW" -X cancel 2>/dev/null || true

# Wait briefly for UI
sleep 0.5

# Send the message as literal text (-l prevents key name interpretation)
tmux $TMUX_FLAGS send-keys -l -t "$WINDOW" "$MESSAGE"

# Brief delay to let TUI process the text before submitting
sleep 0.5

# Send Enter to submit
tmux $TMUX_FLAGS send-keys -t "$WINDOW" Enter

echo "Message sent to $WINDOW: $MESSAGE"