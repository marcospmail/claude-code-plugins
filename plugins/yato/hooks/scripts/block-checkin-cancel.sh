#!/bin/bash
# PreToolUse hook: Block agents from running checkin cancel.
# Only the user (manually) or the automatic background process can cancel check-ins.
#
# Logic:
# 1. Read JSON from stdin (PreToolUse Bash hook)
# 2. Extract command from tool_input
# 3. If command doesn't contain checkin cancel patterns → allow (exit 0)
# 4. Detect role via identity.yml scanning (shared role_detection module)
# 5. If agent → block (exit 2)
# 6. Otherwise → allow (it's the user)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PLUGIN_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

INPUT=$(cat)

# Extract the command from tool_input
COMMAND=$(echo "$INPUT" | uv run --directory "$PLUGIN_ROOT" python -c "
import sys, json
try:
    data = json.load(sys.stdin)
    tool_input = data.get('tool_input', {}) or data.get('toolInput', {})
    print(tool_input.get('command', ''))
except:
    print('')
" 2>/dev/null)

# If no command or doesn't contain checkin cancel patterns → allow
if [[ -z "$COMMAND" ]]; then
    exit 0
fi

# Check if command contains checkin cancel patterns
if ! echo "$COMMAND" | grep -qE '(checkin_scheduler\.py\s+cancel|checkin\s+cancel)'; then
    exit 0
fi

# Command is a checkin cancel - detect role via identity.yml scanning
ROLE=$(HOOK_CWD="${HOOK_CWD:-$(pwd)}" uv run --directory "$PLUGIN_ROOT" python -c "
import sys
sys.path.insert(0, '$SCRIPT_DIR')
from role_detection import detect_role
role = detect_role()
if role:
    print(role)
" 2>/dev/null)

if [[ -n "$ROLE" ]]; then
    echo "BLOCKED: Agents cannot cancel check-ins. Only the user can cancel check-ins manually via /cancel-checkin."
    exit 2
fi

# Not an agent - allow
exit 0
