#!/bin/bash
# notify-pm.sh - Send message to PM
# PM is always at window 0, pane 1 (pane 0 is check-ins display)
#
# Appends stacked suffixes:
#   1. AGENTS_TO_PM_SUFFIX from defaults.conf (yato-level)
#   2. agent_to_pm_message_suffix from workflow status.yml (workflow-level)
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

# Support isolated tmux socket (used by e2e tests)
TMUX_FLAGS="${TMUX_SOCKET:+-L $TMUX_SOCKET}"

# Auto-detect current session
SESSION=$(tmux $TMUX_FLAGS display-message -p '#S' 2>/dev/null)
if [[ -z "$SESSION" ]]; then
    echo "Error: Not running in a tmux session"
    exit 1
fi

MESSAGE="$*"

# --- Yato-level suffix (AGENTS_TO_PM_SUFFIX from defaults.conf) ---
YATO_SUFFIX=""
DEFAULTS_CONF="${YATO_PATH:-$YATO_ROOT}/config/defaults.conf"
if [[ -f "$DEFAULTS_CONF" ]]; then
    _raw=$(grep '^AGENTS_TO_PM_SUFFIX=' "$DEFAULTS_CONF" | head -1 | cut -d= -f2-)
    # Strip surrounding quotes
    _raw="${_raw#\"}"
    _raw="${_raw%\"}"
    _raw="${_raw#\'}"
    _raw="${_raw%\'}"
    YATO_SUFFIX="$_raw"
fi

# --- Workflow-level suffix (agent_to_pm_message_suffix from status.yml) ---
WORKFLOW_SUFFIX=""
# Find workflow status.yml via WORKFLOW_NAME tmux env var
WORKFLOW_NAME=$(tmux $TMUX_FLAGS showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
if [[ -n "$WORKFLOW_NAME" && "$WORKFLOW_NAME" != "-WORKFLOW_NAME" ]]; then
    # Search for .workflow directory from current pane path
    PANE_PATH=$(tmux $TMUX_FLAGS display-message -p '#{pane_current_path}' 2>/dev/null)
    if [[ -n "$PANE_PATH" ]]; then
        _search="$PANE_PATH"
        while [[ "$_search" != "/" ]]; do
            if [[ -f "$_search/.workflow/$WORKFLOW_NAME/status.yml" ]]; then
                _raw=$(grep '^agent_to_pm_message_suffix:' "$_search/.workflow/$WORKFLOW_NAME/status.yml" | head -1 | sed "s/^agent_to_pm_message_suffix: *//" | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//")
                WORKFLOW_SUFFIX="$_raw"
                break
            fi
            _search="$(dirname "$_search")"
        done
    fi
fi

# --- Stack suffixes onto message ---
if [[ -n "$YATO_SUFFIX" ]]; then
    MESSAGE="$MESSAGE

$YATO_SUFFIX"
fi
if [[ -n "$WORKFLOW_SUFFIX" ]]; then
    MESSAGE="$MESSAGE

$WORKFLOW_SUFFIX"
fi

# PM is always at window 0, pane 1
PM_TARGET="$SESSION:0.1"

# Send message to PM using send-message.sh
"$SCRIPT_DIR/send-message.sh" "$PM_TARGET" "$MESSAGE"
