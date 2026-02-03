#!/bin/bash
# tasks-table.sh - Display tasks.json in table format
#
# Usage: tasks-table.sh [project-path]
#
# Outputs tasks in the format:
# | ID | Task | Agent | Status |
# |----|------|-------|--------|
# | T1 | Task description | developer | pending |
# | T2 | Another task | qa | blocked by T1 |

PROJECT_PATH="${1:-$(pwd)}"

# Get workflow name from tmux env var
CURRENT_WORKFLOW=""
if [[ -n "$TMUX" ]]; then
    CURRENT_WORKFLOW=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
fi

# Determine tasks file path based on workflow
if [[ -n "$CURRENT_WORKFLOW" && "$CURRENT_WORKFLOW" != "-WORKFLOW_NAME" ]]; then
    TASKS_FILE="$PROJECT_PATH/.workflow/$CURRENT_WORKFLOW/tasks.json"
else
    # Fallback: find first numbered workflow folder (for display purposes only)
    FIRST_WORKFLOW=$(ls "$PROJECT_PATH/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
    if [[ -n "$FIRST_WORKFLOW" ]]; then
        TASKS_FILE="$PROJECT_PATH/.workflow/$FIRST_WORKFLOW/tasks.json"
    else
        TASKS_FILE="$PROJECT_PATH/.workflow/tasks.json"
    fi
fi

if [[ ! -f "$TASKS_FILE" ]]; then
    echo "(no tasks file found)"
    exit 0
fi

python3 << PYEOF
import json

try:
    with open('$TASKS_FILE', 'r') as f:
        data = json.load(f)

    tasks = data.get('tasks', [])
    if not tasks:
        print("(no tasks)")
        exit(0)

    # Print table header
    print("| ID | Task | Agent | Status |")
    print("|----|------|-------|--------|")

    for task in tasks:
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:40]
        agent = task.get('agent', '?')
        status = task.get('status', 'pending')
        blocked_by = task.get('blockedBy', [])

        # Format status column
        if status == 'blocked' or (status == 'pending' and blocked_by):
            if blocked_by:
                status_display = f"blocked by {', '.join(blocked_by)}"
            else:
                status_display = "blocked"
        else:
            status_display = status

        print(f"| {task_id} | {subject} | {agent} | {status_display} |")

except Exception as e:
    print(f"(error: {e})")
PYEOF
