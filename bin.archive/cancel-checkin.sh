#!/bin/bash
# cancel-checkin.sh - Cancel all pending check-ins
# Usage: ./cancel-checkin.sh
#
# Reads WORKFLOW_NAME from tmux environment variable.
# Cancels check-ins in .workflow/$WORKFLOW_NAME/checkins.json

# Get workflow name from tmux environment variable
if [[ -n "$TMUX" ]]; then
    CURRENT_WORKFLOW=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
fi

# Validate workflow
if [[ -z "$CURRENT_WORKFLOW" ]]; then
    echo "Error: No WORKFLOW_NAME set in tmux environment."
    echo "Run this from within a tmux session with an active workflow."
    exit 1
fi

if [[ ! -d ".workflow/$CURRENT_WORKFLOW" ]]; then
    echo "Error: Workflow directory not found: .workflow/$CURRENT_WORKFLOW"
    exit 1
fi

STATE_DIR=".workflow/$CURRENT_WORKFLOW"

CHECKIN_FILE="$STATE_DIR/checkins.json"

if [[ ! -f "$CHECKIN_FILE" ]]; then
    echo "No check-ins file found at $CHECKIN_FILE"
    exit 0
fi

# Mark all pending check-ins as cancelled and add a "stopped" entry
python3 -c "
import json
from datetime import datetime

try:
    with open('$CHECKIN_FILE', 'r') as f:
        data = json.load(f)

    cancelled_count = 0
    for c in data['checkins']:
        if c.get('status') == 'pending':
            c['status'] = 'cancelled'
            c['cancelled_at'] = datetime.now().isoformat()
            cancelled_count += 1

    # Add a new entry indicating check-ins were stopped
    data['checkins'].append({
        'id': 'stop-' + str(int(datetime.now().timestamp())),
        'status': 'stopped',
        'note': 'Check-in loop stopped - all work complete',
        'created_at': datetime.now().isoformat()
    })

    with open('$CHECKIN_FILE', 'w') as f:
        json.dump(data, f, indent=2)

    print(f'Cancelled {cancelled_count} pending check-in(s).')
except Exception as e:
    print(f'Error: {e}')
"

# Note: check-in interval is stored in status.yml, no need to clear separate file

echo "Check-in loop stopped."
