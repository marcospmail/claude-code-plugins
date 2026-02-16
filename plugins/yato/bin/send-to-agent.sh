#!/bin/bash
# send-to-agent.sh - Send message from PM to an agent
# Looks up agent target from agents.yml and sends via send-message.sh
#
# Appends stacked suffixes:
#   1. PM_TO_AGENTS_SUFFIX from defaults.conf (yato-level)
#   2. agent_message_suffix from workflow status.yml (workflow-level)
#
# Usage: send-to-agent.sh <agent-name> "<message>"
# Example: send-to-agent.sh developer "Please work on T1"

if [ $# -lt 2 ]; then
    echo "Usage: $0 <agent-name> <message>"
    echo "Example: $0 developer 'Please work on T1 — check your agent-tasks.md'"
    exit 1
fi

AGENT_NAME="$1"
shift
MESSAGE="$*"

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

# --- Find workflow directory ---
# Get pane's working directory to find .workflow
PANE_PATH=$(tmux $TMUX_FLAGS display-message -p '#{pane_current_path}' 2>/dev/null)
if [[ -z "$PANE_PATH" ]]; then
    echo "Error: Cannot determine pane working directory"
    exit 1
fi

# Search upward for .workflow directory
PROJECT_ROOT=""
_search="$PANE_PATH"
while [[ "$_search" != "/" ]]; do
    if [[ -d "$_search/.workflow" ]]; then
        PROJECT_ROOT="$_search"
        break
    fi
    _search="$(dirname "$_search")"
done

if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: No .workflow directory found (searched from $PANE_PATH)"
    exit 1
fi

# Get workflow name
WORKFLOW_NAME=$(tmux $TMUX_FLAGS showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
if [[ -z "$WORKFLOW_NAME" || "$WORKFLOW_NAME" == "-WORKFLOW_NAME" ]]; then
    # Fallback: most recent numbered folder
    WORKFLOW_NAME=$(ls -td "$PROJECT_ROOT/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null)
fi

if [[ -z "$WORKFLOW_NAME" ]]; then
    echo "Error: No workflow found"
    exit 1
fi

WORKFLOW_PATH="$PROJECT_ROOT/.workflow/$WORKFLOW_NAME"
AGENTS_FILE="$WORKFLOW_PATH/agents.yml"

if [[ ! -f "$AGENTS_FILE" ]]; then
    echo "Error: agents.yml not found at $AGENTS_FILE"
    exit 1
fi

# --- Look up agent target from agents.yml ---
AGENT_TARGET=$(uv run --directory "$YATO_ROOT" python -c "
import yaml, sys
with open('$AGENTS_FILE') as f:
    data = yaml.safe_load(f)
for agent in data.get('agents', []):
    if agent.get('name') == '$AGENT_NAME':
        session = agent.get('session', '$SESSION')
        window = agent.get('window', '')
        pane = agent.get('pane')
        if pane is not None:
            print(f'{session}:{window}.{pane}')
        else:
            print(f'{session}:{window}')
        sys.exit(0)
print('')
sys.exit(1)
" 2>/dev/null)

if [[ -z "$AGENT_TARGET" ]]; then
    # List available agents for helpful error
    AVAILABLE=$(uv run --directory "$YATO_ROOT" python -c "
import yaml
with open('$AGENTS_FILE') as f:
    data = yaml.safe_load(f)
for agent in data.get('agents', []):
    name = agent.get('name', '?')
    role = agent.get('role', '?')
    window = agent.get('window', '?')
    print(f'  - {name} ({role}) at window {window}')
" 2>/dev/null)
    echo "Error: Agent '$AGENT_NAME' not found in agents.yml"
    if [[ -n "$AVAILABLE" ]]; then
        echo "Available agents:"
        echo "$AVAILABLE"
    fi
    exit 1
fi

# --- Yato-level suffix (PM_TO_AGENTS_SUFFIX from defaults.conf) ---
YATO_SUFFIX=""
DEFAULTS_CONF="${YATO_PATH:-$YATO_ROOT}/config/defaults.conf"
if [[ -f "$DEFAULTS_CONF" ]]; then
    _raw=$(grep '^PM_TO_AGENTS_SUFFIX=' "$DEFAULTS_CONF" | head -1 | cut -d= -f2-)
    _raw="${_raw#\"}"
    _raw="${_raw%\"}"
    _raw="${_raw#\'}"
    _raw="${_raw%\'}"
    YATO_SUFFIX="$_raw"
fi

# --- Workflow-level suffix (agent_message_suffix from status.yml) ---
WORKFLOW_SUFFIX=""
STATUS_FILE="$WORKFLOW_PATH/status.yml"
if [[ -f "$STATUS_FILE" ]]; then
    _raw=$(grep '^agent_message_suffix:' "$STATUS_FILE" | head -1 | sed "s/^agent_message_suffix: *//" | sed 's/^"//' | sed 's/"$//' | sed "s/^'//" | sed "s/'$//")
    WORKFLOW_SUFFIX="$_raw"
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

# --- Send message ---
"$SCRIPT_DIR/send-message.sh" "$AGENT_TARGET" "$MESSAGE"
