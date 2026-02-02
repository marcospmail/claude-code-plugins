#!/bin/bash
# schedule-checkin.sh - Schedule a check-in with tracking
# Usage: ./schedule-checkin.sh <minutes> "<note>" [target_window]
#
# Reads WORKFLOW_NAME from tmux environment variable.
# Check-ins are stored in .workflow/$WORKFLOW_NAME/checkins.json
# Auto-continues until all tasks in tasks.json are complete (no pending/in_progress/blocked)

MINUTES=${1:-3}
NOTE=${2:-"Standard check-in"}
TARGET=${3:-"tmux-orc:0"}

# Get script directory for bin/ scripts
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Find project root by walking up directories looking for .workflow/
find_project_root() {
    local dir="$PWD"
    while [[ "$dir" != "/" ]]; do
        if [[ -d "$dir/.workflow" ]]; then
            echo "$dir"
            return 0
        fi
        dir="$(dirname "$dir")"
    done
    return 1
}

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

# Find project root (allows running from subdirectories)
PROJECT_ROOT=$(find_project_root)
if [[ -z "$PROJECT_ROOT" ]]; then
    echo "Error: Could not find .workflow/ directory."
    echo "Make sure you're in a project with an active workflow, or in one of its subdirectories."
    exit 1
fi

# Change to project root for relative paths
cd "$PROJECT_ROOT" || exit 1

if [[ ! -d ".workflow/$CURRENT_WORKFLOW" ]]; then
    echo "Error: Workflow directory not found: $PROJECT_ROOT/.workflow/$CURRENT_WORKFLOW"
    exit 1
fi

STATE_DIR=".workflow/$CURRENT_WORKFLOW"

CHECKIN_FILE="$STATE_DIR/checkins.json"
INTERVAL_FILE="$STATE_DIR/checkin_interval.txt"

# Initialize checkin file if it doesn't exist
mkdir -p "$STATE_DIR"
if [[ ! -f "$CHECKIN_FILE" ]]; then
    echo '{"checkins": []}' > "$CHECKIN_FILE"
fi

# GUARD: Check if there's already a pending check-in - prevent parallel loops
EXISTING_PENDING=$(python3 -c "
import json
try:
    with open('$CHECKIN_FILE', 'r') as f:
        data = json.load(f)
    pending = [c for c in data.get('checkins', []) if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$EXISTING_PENDING" -gt 0 ]]; then
    echo "Note: Check-in already pending ($EXISTING_PENDING). Skipping duplicate schedule."
    echo "To force a new check-in, cancel the existing one first with cancel-checkin.sh"
    exit 0
fi

# Store the check-in interval for display
echo "$MINUTES" > "$INTERVAL_FILE"

# Calculate scheduled time
SCHEDULED_FOR=$(date -v +${MINUTES}M +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -d "+${MINUTES} minutes" +"%Y-%m-%dT%H:%M:%S" 2>/dev/null)
CHECKIN_ID=$(date +%s)

# Add pending check-in to tracking file and resumed entry if needed
python3 -c "
import json
from datetime import datetime

checkin_file = '$CHECKIN_FILE'
try:
    with open(checkin_file, 'r') as f:
        data = json.load(f)
except:
    data = {'checkins': []}

# Check if last entry was 'stopped' - if so, add 'resumed' entry
if data['checkins'] and data['checkins'][-1].get('status') == 'stopped':
    data['checkins'].append({
        'id': 'resume-' + str(int(datetime.now().timestamp())),
        'status': 'resumed',
        'note': 'Check-in loop resumed',
        'created_at': datetime.now().isoformat()
    })

# Add new pending check-in
data['checkins'].append({
    'id': '$CHECKIN_ID',
    'status': 'pending',
    'scheduled_for': '$SCHEDULED_FOR',
    'note': '''$NOTE''',
    'target': '$TARGET',
    'created_at': datetime.now().isoformat()
})

with open(checkin_file, 'w') as f:
    json.dump(data, f, indent=2)
"

echo "Scheduling check in $MINUTES minutes with note: $NOTE"

# Calculate the exact time when the check will run
CURRENT_TIME=$(date +"%H:%M:%S")
RUN_TIME=$(date -v +${MINUTES}M +"%H:%M:%S" 2>/dev/null || date -d "+${MINUTES} minutes" +"%H:%M:%S" 2>/dev/null)

# Use bc for minute to seconds calculation
SLEEP_SECONDS=$(echo "$MINUTES * 60" | bc)

# Store PWD for the background process (it needs to run from same directory)
PROJECT_DIR="$PWD"

# Create the check-in execution script that also updates status and auto-continues
EXEC_SCRIPT=$(mktemp)
cat > "$EXEC_SCRIPT" << 'SCRIPT_EOF'
#!/bin/bash
CHECKIN_ID="$1"
TARGET="$2"
NOTE="$3"
SCRIPT_DIR="$4"
CHECKIN_FILE="$5"
PROJECT_DIR="$6"
WORKFLOW_NAME="$7"

# Change to project directory for relative paths
cd "$PROJECT_DIR" || exit 1

# CRITICAL: Check if the check-in was cancelled BEFORE executing
# This prevents cancelled check-ins from running and scheduling more
WAS_CANCELLED=$(python3 -c "
import json
try:
    with open('$CHECKIN_FILE', 'r') as f:
        data = json.load(f)
    for c in data['checkins']:
        if c['id'] == '$CHECKIN_ID':
            if c.get('status') in ('cancelled', 'done'):
                print('yes')
            else:
                print('no')
            break
    else:
        print('yes')  # Not found = don't execute
except:
    print('yes')  # Error = don't execute
" 2>/dev/null)

if [[ "$WAS_CANCELLED" == "yes" ]]; then
    # Check-in was cancelled or already done - do NOT execute
    exit 0
fi

# Mark check-in as done
python3 -c "
import json
from datetime import datetime

try:
    with open('$CHECKIN_FILE', 'r') as f:
        data = json.load(f)

    for c in data['checkins']:
        if c['id'] == '$CHECKIN_ID':
            c['status'] = 'done'
            c['completed_at'] = datetime.now().isoformat()
            break

    with open('$CHECKIN_FILE', 'w') as f:
        json.dump(data, f, indent=2)
except Exception as e:
    pass
"

# Send the check-in message using send-message.sh
"$SCRIPT_DIR/send-message.sh" "$TARGET" "Time for check-in! Note: $NOTE"

# AUTO-CONTINUE: Check if there are incomplete tasks in tasks.json
# Use workflow name passed as parameter (TMUX env not available in detached process)
CURRENT_WORKFLOW="$WORKFLOW_NAME"

if [[ -n "$CURRENT_WORKFLOW" && -d ".workflow/$CURRENT_WORKFLOW" ]]; then
    TASKS_FILE=".workflow/$CURRENT_WORKFLOW/tasks.json"
    STATUS_FILE=".workflow/$CURRENT_WORKFLOW/status.yml"
    LOOP_CHECKIN_FILE=".workflow/$CURRENT_WORKFLOW/checkins.json"

    # Check if loop was stopped before auto-continuing
    LOOP_STOPPED=$(python3 -c "
import json
try:
    with open('$LOOP_CHECKIN_FILE', 'r') as f:
        data = json.load(f)
    checkins = data.get('checkins', [])
    # Find most recent stopped/resumed
    last_stop = None
    last_resume = None
    for c in checkins:
        if c.get('status') == 'stopped':
            last_stop = c.get('created_at', '')
        elif c.get('status') == 'resumed':
            last_resume = c.get('created_at', '')
    # If stopped is more recent than resumed, loop is stopped
    if last_stop and (not last_resume or last_stop > last_resume):
        print('yes')
    else:
        print('no')
except:
    print('no')
" 2>/dev/null)

    if [[ "$LOOP_STOPPED" == "yes" ]]; then
        # Loop was stopped - do not auto-continue
        exit 0
    fi

    if [[ -f "$TASKS_FILE" ]]; then
        # Check for incomplete tasks (pending, in_progress, or blocked) using Python JSON parsing
        INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TASKS_FILE', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

        if [[ "$INCOMPLETE" -gt 0 ]]; then
            # Get interval from status.yml (default to 5 minutes)
            INTERVAL=5
            if [[ -f "$STATUS_FILE" ]]; then
                INTERVAL=$(grep 'checkin_interval_minutes' "$STATUS_FILE" 2>/dev/null | awk '{print $2}')
                INTERVAL=${INTERVAL:-5}
            fi

            # Schedule next check-in (runs from PROJECT_DIR)
            "$SCRIPT_DIR/schedule-checkin.sh" "$INTERVAL" "Auto check-in ($INCOMPLETE tasks remaining)" "$TARGET"
        else
            # All tasks done - update workflow status and stop the loop
            python3 -c "
import re
from datetime import datetime

status_file = '$STATUS_FILE'
try:
    with open(status_file, 'r') as f:
        content = f.read()

    # Update status to completed
    content = re.sub(r'^status:.*$', 'status: completed', content, flags=re.MULTILINE)

    # Add completion timestamp if not present
    if 'completed_at:' not in content:
        content = content.rstrip() + '\ncompleted_at: ' + datetime.now().isoformat() + '\n'
    else:
        content = re.sub(r'^completed_at:.*$', 'completed_at: ' + datetime.now().isoformat(), content, flags=re.MULTILINE)

    with open(status_file, 'w') as f:
        f.write(content)
except Exception as e:
    pass
" 2>/dev/null
            "$SCRIPT_DIR/cancel-checkin.sh"
            "$SCRIPT_DIR/send-message.sh" "$TARGET" "All tasks complete! Workflow marked as completed. Check-in loop stopped."
        fi
    fi
fi
SCRIPT_EOF

chmod +x "$EXEC_SCRIPT"

# Use nohup to completely detach the sleep process
# Pass CURRENT_WORKFLOW as 7th param since $TMUX won't be available in detached process
nohup bash -c "sleep $SLEEP_SECONDS && bash '$EXEC_SCRIPT' '$CHECKIN_ID' '$TARGET' '$NOTE' '$SCRIPT_DIR' '$CHECKIN_FILE' '$PROJECT_DIR' '$CURRENT_WORKFLOW'" > /dev/null 2>&1 &

# Get the PID of the background process
SCHEDULE_PID=$!

echo "Scheduled successfully - process detached (PID: $SCHEDULE_PID)"
echo "SCHEDULED TO RUN AT: $RUN_TIME (in $MINUTES minutes from $CURRENT_TIME)"
echo "Check-in ID: $CHECKIN_ID"
