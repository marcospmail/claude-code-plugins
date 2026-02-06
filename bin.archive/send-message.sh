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

# First select the target pane to ensure it's active
tmux $TMUX_FLAGS select-pane -t "$WINDOW" 2>/dev/null || true

# Exit copy mode if active (prevents search mode trigger from / in paths)
tmux $TMUX_FLAGS send-keys -t "$WINDOW" -X cancel 2>/dev/null || true

# Ctrl+S to stash any current text in the input (Claude Code feature)
# Only send if target appears to be Claude (check for common shell prompts)
# Skip for now - Ctrl+S can interfere with shells that aren't Claude
# tmux $TMUX_FLAGS send-keys -t "$WINDOW" C-s
# sleep 0.2
# tmux $TMUX_FLAGS send-keys -t "$WINDOW" C-g

# Wait briefly
sleep 0.5

# Send the message
tmux $TMUX_FLAGS send-keys -t "$WINDOW" "$MESSAGE"

# Wait for UI to process the text
sleep 1

# Send Enter to submit
tmux $TMUX_FLAGS send-keys -t "$WINDOW" Enter

echo "Message sent to $WINDOW: $MESSAGE"