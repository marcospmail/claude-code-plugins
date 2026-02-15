#!/bin/bash
# schedule-checkin.sh - Start the check-in daemon
# Wrapper for checkin_scheduler.py start
#
# Usage: schedule-checkin.sh <interval_minutes> [note] [target]
# Example: schedule-checkin.sh 5 'Check team progress' 'myproject:0.1'

if [ $# -lt 1 ]; then
    echo "Usage: $0 <interval_minutes> [note] [target]"
    echo "Example: $0 5 'Check team progress' 'myproject:0.1'"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$SCRIPT_DIR/../lib"

INTERVAL="$1"
NOTE="${2:-Check team progress}"
TARGET="${3:-}"

# Build command args
CMD_ARGS="start $INTERVAL --note \"$NOTE\""
if [ -n "$TARGET" ]; then
    CMD_ARGS="$CMD_ARGS --target \"$TARGET\""
fi

cd "$SCRIPT_DIR/.." && eval uv run python lib/checkin_scheduler.py $CMD_ARGS
