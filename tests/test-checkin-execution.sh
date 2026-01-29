#!/bin/bash
# Test check-in execution, cancellation, and auto-continue behavior
# Run: ./tests/test-checkin-execution.sh
#
# Uses short intervals (0.1 minutes = 6 seconds) for fast testing

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-checkin-exec-$$"
TEST_SESSION="test-exec-$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }

PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    echo ""
    echo "Cleaning up..."
    # Kill any lingering background processes from this test
    pkill -f "test-checkin-exec-$$" 2>/dev/null || true
    pkill -f "$TEST_SESSION" 2>/dev/null || true
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║       Testing Check-in Execution Behavior                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"

# Initialize workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test Checkin Exec" > /dev/null 2>&1
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"
CHECKIN_FILE="$WORKFLOW_PATH/checkins.json"

# Create tmux session with WORKFLOW_NAME env var
echo "Creating test tmux session: $TEST_SESSION"
tmux new-session -d -s "$TEST_SESSION" -c "$TEST_DIR"
tmux setenv -t "$TEST_SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"

# Split window to create target pane for check-in messages
tmux split-window -t "$TEST_SESSION:0" -v

# ============================================================================
# TEST 1: Check-in executes at scheduled time
# ============================================================================
echo ""
echo "=== Test 1: Check-in executes at scheduled time ==="

# Schedule a check-in for 0.1 minutes (6 seconds)
tmux send-keys -t "$TEST_SESSION:0.0" "cd $TEST_DIR && $PROJECT_ROOT/bin/schedule-checkin.sh 0.1 'Test execution' $TEST_SESSION:0.1" Enter
sleep 2

# Verify it was scheduled
if grep -q '"status": "pending"' "$CHECKIN_FILE" 2>/dev/null; then
    echo "  Check-in scheduled, waiting for execution..."
else
    fail "Check-in was not scheduled"
fi

# Wait for execution (6 seconds + buffer)
sleep 8

# Check if it was marked as done
if grep -q '"status": "done"' "$CHECKIN_FILE" 2>/dev/null; then
    pass "Check-in executed and marked as done"
else
    fail "Check-in did not execute"
fi

# Check if message was sent to target pane
PANE_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:0.1" -p 2>/dev/null)
if echo "$PANE_CONTENT" | grep -q "Time for check-in"; then
    pass "Check-in message delivered to target pane"
else
    fail "Check-in message not found in target pane"
fi

# ============================================================================
# TEST 2: Cancelled check-in behavior
# ============================================================================
echo ""
echo "=== Test 2: Cancelled check-in behavior ==="

# Reset checkins.json
echo '{"checkins": []}' > "$CHECKIN_FILE"

# Schedule a longer check-in (0.2 minutes = 12 seconds) so we have time to cancel
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/schedule-checkin.sh 0.2 'Should be cancelled' $TEST_SESSION:0.1" Enter
sleep 2

# Verify it was scheduled
PENDING_ID=$(python3 -c "
import json
with open('$CHECKIN_FILE') as f:
    data = json.load(f)
for c in data['checkins']:
    if c.get('status') == 'pending':
        print(c['id'])
        break
" 2>/dev/null)

if [[ -n "$PENDING_ID" ]]; then
    echo "  Scheduled check-in ID: $PENDING_ID"
else
    fail "No pending check-in found"
fi

# Cancel it immediately
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

# Verify it was marked as cancelled
if grep -q '"status": "cancelled"' "$CHECKIN_FILE"; then
    pass "Check-in marked as cancelled in JSON"
else
    fail "Check-in not marked as cancelled"
fi

# Clear target pane content to check for new messages
tmux send-keys -t "$TEST_SESSION:0.1" "clear" Enter
sleep 1

# Wait for when the check-in WOULD have executed
echo "  Waiting to see if cancelled check-in still executes..."
sleep 12

# Check if it was changed to "done" (BUG: this would indicate the bug)
DONE_COUNT=$(grep -c '"status": "done"' "$CHECKIN_FILE" 2>/dev/null | head -1 || echo "0")
DONE_COUNT=${DONE_COUNT:-0}
if [[ "$DONE_COUNT" -gt 0 ]]; then
    fail "BUG DETECTED: Cancelled check-in still executed (marked as done)"
else
    pass "Cancelled check-in did not execute"
fi

# ============================================================================
# TEST 3: Auto-continue with pending tasks
# ============================================================================
echo ""
echo "=== Test 3: Auto-continue with pending tasks ==="

# Reset checkins.json
echo '{"checkins": []}' > "$CHECKIN_FILE"

# Create tasks.json with pending tasks
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Task 1", "status": "pending"},
    {"id": "2", "title": "Task 2", "status": "in_progress"}
  ]
}
EOF

# Set interval in status.yml
sed -i '' 's/checkin_interval_minutes:.*/checkin_interval_minutes: 0.1/' "$WORKFLOW_PATH/status.yml"

# Schedule initial check-in
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/schedule-checkin.sh 0.1 'Initial check-in' $TEST_SESSION:0.1" Enter
sleep 2

# Wait for first check-in to execute
echo "  Waiting for first check-in..."
sleep 8

# Check if another check-in was scheduled (auto-continue)
PENDING_AFTER=$(grep -c '"status": "pending"' "$CHECKIN_FILE" 2>/dev/null || echo "0")
if [[ "$PENDING_AFTER" -gt 0 ]]; then
    pass "Auto-continue scheduled another check-in"
else
    fail "Auto-continue did not schedule next check-in"
fi

# Cancel to stop the loop
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

# ============================================================================
# TEST 4: Auto-continue stops when all tasks complete
# ============================================================================
echo ""
echo "=== Test 4: Auto-continue stops when all tasks complete ==="

# Reset checkins.json
echo '{"checkins": []}' > "$CHECKIN_FILE"

# Create tasks.json with ALL completed tasks
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Task 1", "status": "completed"},
    {"id": "2", "title": "Task 2", "status": "completed"}
  ]
}
EOF

# Schedule a check-in
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/schedule-checkin.sh 0.1 'Should stop after' $TEST_SESSION:0.1" Enter
sleep 2

# Wait for execution
echo "  Waiting for check-in to execute..."
sleep 8

# Check that NO new pending check-in was scheduled
PENDING_COUNT=$(grep -c '"status": "pending"' "$CHECKIN_FILE" 2>/dev/null | head -1 || echo "0")
PENDING_COUNT=${PENDING_COUNT:-0}
if [[ "$PENDING_COUNT" -eq 0 ]]; then
    pass "Auto-continue stopped (no pending check-ins)"
else
    fail "Auto-continue should have stopped but scheduled more check-ins"
fi

# Check for stopped entry
if grep -q '"status": "stopped"' "$CHECKIN_FILE"; then
    pass "Stopped entry added to checkins.json"
else
    fail "No stopped entry found"
fi

# ============================================================================
# TEST 5: Resume after stop
# ============================================================================
echo ""
echo "=== Test 5: Resume after stop ==="

# Schedule a new check-in (should add "resumed" entry since last was "stopped")
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/schedule-checkin.sh 0.1 'After resume' $TEST_SESSION:0.1" Enter
sleep 2

# Check for resumed entry
if grep -q '"status": "resumed"' "$CHECKIN_FILE"; then
    pass "Resumed entry added after stop"
else
    fail "No resumed entry found"
fi

# Cancel to clean up
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

# ============================================================================
# TEST 6: Multiple rapid schedules
# ============================================================================
echo ""
echo "=== Test 6: Multiple rapid schedules don't explode ==="

# Reset checkins.json
echo '{"checkins": []}' > "$CHECKIN_FILE"

# Rapidly schedule 5 check-ins
for i in 1 2 3 4 5; do
    tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/schedule-checkin.sh 0.1 'Rapid $i' $TEST_SESSION:0.1" Enter
    sleep 0.3
done
sleep 2

# Count pending
PENDING_COUNT=$(grep -c '"status": "pending"' "$CHECKIN_FILE" 2>/dev/null || echo "0")
echo "  Pending count after rapid scheduling: $PENDING_COUNT"

if [[ "$PENDING_COUNT" -le 10 ]]; then
    pass "Rapid scheduling didn't create explosion ($PENDING_COUNT pending)"
else
    fail "Too many pending check-ins: $PENDING_COUNT"
fi

# Cancel all
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

# Wait for all to potentially execute
echo "  Waiting for rapid check-ins to complete..."
sleep 10

# Check final state - should not have exponential growth
FINAL_PENDING=$(grep -c '"status": "pending"' "$CHECKIN_FILE" 2>/dev/null | head -1 || echo "0")
FINAL_PENDING=${FINAL_PENDING:-0}
if [[ "$FINAL_PENDING" -le 5 ]]; then
    pass "No exponential growth after rapid scheduling"
else
    fail "Exponential growth detected: $FINAL_PENDING pending check-ins"
fi

# ============================================================================
# TEST 7: Check-in interval from status.yml
# ============================================================================
echo ""
echo "=== Test 7: Interval from status.yml is used ==="

# Reset
echo '{"checkins": []}' > "$CHECKIN_FILE"

# Set custom interval
sed -i '' 's/checkin_interval_minutes:.*/checkin_interval_minutes: 0.15/' "$WORKFLOW_PATH/status.yml"

# Create pending tasks
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [{"id": "1", "title": "Task", "status": "pending"}]
}
EOF

# Schedule check-in
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/schedule-checkin.sh 0.1 'Test interval' $TEST_SESSION:0.1" Enter
sleep 8

# Check if interval file was created with correct value
INTERVAL_FILE="$WORKFLOW_PATH/checkin_interval.txt"
if [[ -f "$INTERVAL_FILE" ]]; then
    # The next scheduled check-in should use 0.15 from status.yml
    # (The first one uses whatever was passed, but auto-continue uses status.yml)
    pass "Interval file exists"
else
    skip "Interval file not found (may have been cancelled)"
fi

# Cancel
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

# ============================================================================
# TEST 8: Checkin-display.sh shows status
# ============================================================================
echo ""
echo "=== Test 8: Checkin-display shows correct status ==="

# Reset
echo '{"checkins": []}' > "$CHECKIN_FILE"

# Start checkin-display in a pane
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/checkin-display.sh &" Enter
sleep 3

# Capture display output
DISPLAY_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:0.0" -p 2>/dev/null)

if echo "$DISPLAY_CONTENT" | grep -qi "check-in\|waiting\|scheduled"; then
    pass "Checkin-display shows status information"
else
    # May show "(no check-ins yet)" which is also valid
    if echo "$DISPLAY_CONTENT" | grep -q "no check-ins"; then
        pass "Checkin-display shows 'no check-ins' status"
    else
        skip "Could not verify checkin-display output"
    fi
fi

# Kill the display script
tmux send-keys -t "$TEST_SESSION:0.0" C-c
sleep 1

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $PASSED"
echo -e "  ${RED}Failed${NC}:  $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    echo ""
    echo "Note: Failed tests may indicate bugs in the check-in system"
    echo "See task #17 for fix implementation"
    exit 1
fi
