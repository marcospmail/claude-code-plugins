#!/bin/bash
# send-to-agent.sh - Send message from PM to an agent
# Looks up agent target from agents.yml and sends via tmux_utils.py
# Thin wrapper around tmux_utils.py send-to-agent
#
# Usage: send-to-agent.sh <agent-name> "<message>"
# Example: send-to-agent.sh developer "Please work on T1"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <agent-name> <message>"
    echo "Example: $0 developer 'Please work on T1 — check your agent-tasks.md'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YATO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMUX_SOCKET="${TMUX_SOCKET}" uv run --project "$YATO_ROOT" python "$YATO_ROOT/lib/tmux_utils.py" send-to-agent "$@"
