#!/bin/bash
# tasks-display.sh - Display tasks.json content in a tmux pane

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
    # No workflow name available - try finding first workflow folder
    FIRST_WORKFLOW=$(ls "$PROJECT_PATH/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
    if [[ -n "$FIRST_WORKFLOW" ]]; then
        TASKS_FILE="$PROJECT_PATH/.workflow/$FIRST_WORKFLOW/tasks.json"
    else
        TASKS_FILE="$PROJECT_PATH/.workflow/tasks.json"
    fi
fi

# Clear screen once at start
printf '\033[2J\033[H'

while true; do
    # Move cursor to top-left without clearing (prevents flicker)
    printf '\033[H'

    echo "TASKS                              "
    echo "───────────────────────────────────"

    if [[ -f "$TASKS_FILE" ]]; then
        # Display tasks from JSON, formatted nicely
        python3 -c "
import json
import sys

try:
    with open('$TASKS_FILE', 'r') as f:
        data = json.load(f)

    tasks = data.get('tasks', [])
    if not tasks:
        print('(no tasks yet)')
    else:
        # Status icons
        icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}

        for task in tasks[:20]:  # Limit to 20 tasks for display
            status = task.get('status', 'pending')
            icon = icons.get(status, '?')
            task_id = task.get('id', '?')
            subject = task.get('subject', 'No subject')[:45]  # Truncate long subjects
            agent = task.get('agent', '?')

            print(f'{icon} {task_id}: {subject} [{agent}]')

        if len(tasks) > 20:
            print(f'... and {len(tasks) - 20} more tasks')
except Exception as e:
    print(f'(error reading tasks: {e})')
" 2>/dev/null
    else
        echo "(waiting for tasks.json...)"
    fi

    echo ""
    echo "───────────────────────────────────"
    # Clear to end of screen to remove old content
    printf '\033[J'

    sleep 3
done
