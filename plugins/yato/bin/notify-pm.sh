#!/bin/bash
# notify-pm.sh - Send message to PM
# PM is always at window 0, pane 1 (pane 0 is check-ins display)
# Thin wrapper around tmux_utils.py notify
#
# Usage: notify-pm.sh "[DONE] Task completed"
# Usage: notify-pm.sh "[BLOCKED] Need help with X"

if [ $# -lt 1 ]; then
    echo "Usage: $0 <message>"
    echo "Example: $0 '[DONE] Task completed'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
YATO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

TMUX_SOCKET="${TMUX_SOCKET}" uv run --project "$YATO_ROOT" python "$YATO_ROOT/lib/tmux_utils.py" notify "$@"
