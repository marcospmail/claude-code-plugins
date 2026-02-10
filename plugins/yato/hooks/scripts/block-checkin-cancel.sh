#!/bin/bash
# PreToolUse hook: Block agents from running checkin cancel.
# Only the user (manually) or the automatic background process can cancel check-ins.
#
# Logic:
# 1. Read JSON from stdin (PreToolUse Bash hook)
# 2. Extract command from tool_input
# 3. If command doesn't contain checkin cancel patterns → allow (exit 0)
# 4. Check if running as an agent (AGENT_ROLE env var or identity.yml)
# 5. If agent → block (exit 2)
# 6. Otherwise → allow (it's the user)

INPUT=$(cat)

# Extract the command from tool_input
COMMAND=$(echo "$INPUT" | python3 -c "
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

# Command is a checkin cancel - check if we're an agent

# Check AGENT_ROLE environment variable
if [[ -n "$AGENT_ROLE" ]]; then
    echo "BLOCKED: Agents cannot cancel check-ins. Only the user can cancel check-ins manually via /cancel-checkin."
    exit 2
fi

# Check tmux AGENT_ROLE if in tmux
if [[ -n "$TMUX" ]]; then
    TMUX_ROLE=$(tmux showenv AGENT_ROLE 2>/dev/null | grep '=' | cut -d= -f2)
    if [[ -n "$TMUX_ROLE" ]]; then
        echo "BLOCKED: Agents cannot cancel check-ins. Only the user can cancel check-ins manually via /cancel-checkin."
        exit 2
    fi
fi

# Check for identity.yml in current directory
if [[ -f "identity.yml" ]]; then
    ROLE=$(python3 -c "
import yaml, sys
try:
    with open('identity.yml') as f:
        data = yaml.safe_load(f)
    if data and 'role' in data:
        print(data['role'])
except:
    pass
" 2>/dev/null)
    if [[ -n "$ROLE" ]]; then
        echo "BLOCKED: Agents cannot cancel check-ins. Only the user can cancel check-ins manually via /cancel-checkin."
        exit 2
    fi
fi

# Not an agent - allow
exit 0
