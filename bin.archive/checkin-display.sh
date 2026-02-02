#!/bin/bash
# checkin-display.sh - Display check-in status in a tmux pane
# Usage: ./checkin-display.sh
#
# Reads WORKFLOW_NAME from tmux environment variable.
# Displays check-ins from .workflow/$WORKFLOW_NAME/checkins.json
# Re-checks tmux env on each loop iteration (handles workflow creation after startup).

# Get the pane ID this script is running in (must target this specific pane)
MY_PANE=$(tmux display-message -p '#{session_name}:#{window_index}.#{pane_index}' 2>/dev/null)

# Clear screen at start - wait briefly for shell prompt to finish
sleep 0.2
printf '\033[2J\033[H'

while true; do
    # Clear screen and move cursor to top-left (ensures clean display)
    printf '\033[2J\033[H'

    # Get workflow name from tmux environment variable (re-check each iteration for new workflows)
    CURRENT_WORKFLOW=""
    if [[ -n "$TMUX" ]]; then
        CURRENT_WORKFLOW=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
    fi

    # Determine STATE_DIR
    if [[ -n "$CURRENT_WORKFLOW" && -d ".workflow/$CURRENT_WORKFLOW" ]]; then
        STATE_DIR=".workflow/$CURRENT_WORKFLOW"
    else
        STATE_DIR=""
    fi

    CHECKIN_FILE="$STATE_DIR/checkins.json"
    STATUS_FILE="$STATE_DIR/status.yml"

    # Get terminal width for proper formatting
    TERM_WIDTH=$(tput cols 2>/dev/null || echo 80)

    # Update pane title with interval info (appears in tmux pane border)
    # IMPORTANT: Must target our specific pane with -t, otherwise it updates the currently selected pane
    # Read interval from status.yml (single source of truth)
    if [[ -n "$STATE_DIR" && -f "$STATUS_FILE" ]]; then
        INTERVAL=$(grep 'checkin_interval_minutes:' "$STATUS_FILE" 2>/dev/null | awk '{print $2}')
        if [[ -n "$INTERVAL" && "$INTERVAL" != "_" ]]; then
            tmux select-pane -t "$MY_PANE" -T "Check-ins (every ${INTERVAL}m, refresh: 2s)" 2>/dev/null
        else
            tmux select-pane -t "$MY_PANE" -T "Check-ins (refresh: 2s)" 2>/dev/null
        fi
    else
        tmux select-pane -t "$MY_PANE" -T "Check-ins (refresh: 2s)" 2>/dev/null
    fi

    # Display check-ins based on workflow and file state
    if [[ -z "$STATE_DIR" ]]; then
        # No workflow exists yet
        echo -e "(waiting for workflow...)\033[K"
    elif [[ ! -f "$CHECKIN_FILE" ]]; then
        # Workflow exists but no check-ins scheduled yet
        echo -e "(no check-ins scheduled)\033[K"
    else
        # Workflow and checkins.json both exist
        python3 -c "
import json
from datetime import datetime

try:
    with open('$CHECKIN_FILE', 'r') as f:
        data = json.load(f)

    checkins = data.get('checkins', [])

    # Show stopped/resumed entries
    stopped = [c for c in checkins if c.get('status') == 'stopped']
    resumed = [c for c in checkins if c.get('status') == 'resumed']

    if stopped:
        last_stopped = stopped[-1]
        created_at = last_stopped.get('created_at', '')
        time = created_at.split('T')[1][:8] if 'T' in created_at else 'N/A'
        print(f'[stopped] {time}  {last_stopped.get(\"note\", \"Stopped\")[:40]}\033[K')

    if resumed:
        last_resumed = resumed[-1]
        created_at = last_resumed.get('created_at', '')
        time = created_at.split('T')[1][:8] if 'T' in created_at else 'N/A'
        print(f'[resumed] {time}  {last_resumed.get(\"note\", \"Resumed\")[:40]}\033[K')

    # Show completed check-ins
    completed = [c for c in checkins if c.get('status') == 'done']
    completed.sort(key=lambda x: x.get('completed_at', ''))

    for c in completed[-10:]:
        completed_at = c.get('completed_at', '')
        time = completed_at.split('T')[1][:8] if 'T' in completed_at else 'N/A'
        note = c.get('note', 'Check-in')[:40]
        print(f'[done]    {time}  {note}\033[K')

    # Show pending check-ins
    pending = [c for c in checkins if c.get('status') == 'pending']
    if pending:
        pending.sort(key=lambda x: x.get('scheduled_for', ''))
        p = pending[0]
        scheduled = p.get('scheduled_for', '')
        note = p.get('note', 'Check-in')[:40]
        try:
            sched_time = datetime.fromisoformat(scheduled)
            diff = sched_time - datetime.now()
            if diff.total_seconds() > 0:
                mins = int(diff.total_seconds() // 60)
                secs = int(diff.total_seconds() % 60)
                remaining = f'in {mins}m {secs}s'
            else:
                remaining = 'NOW'
        except:
            remaining = 'N/A'
        print(f'[pending] {remaining:>8}  {note}\033[K')

    if not completed and not pending and not stopped and not resumed:
        print('(no check-ins yet)\033[K')

except Exception as e:
    print(f'Error: {e}\033[K')
" 2>/dev/null
    fi

    # Clear to end of screen to remove old content
    printf '\033[J'

    sleep 2
done
