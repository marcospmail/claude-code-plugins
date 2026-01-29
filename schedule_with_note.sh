#!/bin/bash
# Dynamic scheduler with note for next check
# Usage: ./schedule_with_note.sh <minutes> "<note>" [target_window]

MINUTES=${1:-3}
NOTE=${2:-"Standard check-in"}
TARGET=${3:-"tmux-orc:0"}

# Get script directory for portable paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
NOTE_FILE="$SCRIPT_DIR/next_check_note.txt"

# Create a note file for the next check
echo "=== Next Check Note ($(date)) ===" > "$NOTE_FILE"
echo "Scheduled for: $MINUTES minutes" >> "$NOTE_FILE"
echo "Target window: $TARGET" >> "$NOTE_FILE"
echo "" >> "$NOTE_FILE"
echo "$NOTE" >> "$NOTE_FILE"

echo "Scheduling check in $MINUTES minutes with note: $NOTE"

# Calculate the exact time when the check will run
CURRENT_TIME=$(date +"%H:%M:%S")
RUN_TIME=$(date -v +${MINUTES}M +"%H:%M:%S" 2>/dev/null || date -d "+${MINUTES} minutes" +"%H:%M:%S" 2>/dev/null)

# Use bc for minute to seconds calculation
SLEEP_SECONDS=$(echo "$MINUTES * 60" | bc)

# Use nohup to completely detach the sleep process
# Send a check-in prompt to the target window
nohup bash -c "sleep $SLEEP_SECONDS && tmux send-keys -t '$TARGET' 'Time for check-in! Note: $NOTE' && sleep 0.5 && tmux send-keys -t '$TARGET' Enter" > /dev/null 2>&1 &

# Get the PID of the background process
SCHEDULE_PID=$!

echo "Scheduled successfully - process detached (PID: $SCHEDULE_PID)"
echo "SCHEDULED TO RUN AT: $RUN_TIME (in $MINUTES minutes from $CURRENT_TIME)"
echo "Note file: $NOTE_FILE"
