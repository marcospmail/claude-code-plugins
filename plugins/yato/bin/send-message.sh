#!/bin/bash

# Send message to Claude agent in tmux window
# Usage: send-message.sh <session:window> <message>
# Thin wrapper around tmux_utils.py send

if [ $# -lt 2 ]; then
    echo "Usage: $0 <session:window> <message>"
    echo "Example: $0 agentic-seek:3 'Hello Claude!'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YATO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMUX_SOCKET="${TMUX_SOCKET}" uv run --project "$YATO_ROOT" python "$YATO_ROOT/lib/tmux_utils.py" send --skip-suffix "$@"
