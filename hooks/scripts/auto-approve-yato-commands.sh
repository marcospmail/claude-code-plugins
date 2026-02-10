#!/bin/bash
# auto-approve-yato-commands.sh
# PermissionRequest hook that auto-approves Bash commands matching yato scripts
# This allows yato bin/ scripts and lib/ Python commands to run without permission prompts

INPUT=$(cat)

COMMAND=$(echo "$INPUT" | python3 -c "import sys,json; print(json.load(sys.stdin).get('tool_input',{}).get('command',''))" 2>/dev/null)

if [ -z "$COMMAND" ]; then
    exit 0
fi

# Get the yato root directory (parent of hooks/scripts/)
YATO_ROOT="$(cd "$(dirname "$0")/../.." && pwd)"

# Check if the command references yato bin/ or lib/ scripts
if echo "$COMMAND" | grep -qE "(${YATO_ROOT}/bin/|${YATO_ROOT}/lib/|${YATO_ROOT}/bin\.archive/|tools/yato/bin/|tools/yato/lib/)" 2>/dev/null; then
    # Auto-approve yato commands
    cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
ENDJSON
    exit 0
fi

# Check for uv run python commands targeting yato
if echo "$COMMAND" | grep -qE "uv run python.*(tools/yato/|${YATO_ROOT}/)" 2>/dev/null; then
    cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
ENDJSON
    exit 0
fi

# Check for commands using relative paths to lib/ (e.g. after cd to yato dir)
if echo "$COMMAND" | grep -qE "(uv run python lib/|python3? lib/|python3? \./lib/)" 2>/dev/null; then
    cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
ENDJSON
    exit 0
fi

# Check for checkin_scheduler or tasks-change-hook commands
if echo "$COMMAND" | grep -qE "(checkin_scheduler\.py|tasks-change-hook\.py)" 2>/dev/null; then
    cat <<'ENDJSON'
{
  "hookSpecificOutput": {
    "hookEventName": "PermissionRequest",
    "decision": {
      "behavior": "allow"
    }
  }
}
ENDJSON
    exit 0
fi

# Not a yato command, let the normal permission flow handle it
exit 0
