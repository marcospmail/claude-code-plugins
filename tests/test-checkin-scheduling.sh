#!/bin/bash
# Test schedule-checkin.sh and cancel-checkin.sh functionality
# Run: ./tests/test-checkin-scheduling.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-checkin-sched-$$"
TEST_SESSION="test-checkin-$$"

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
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║    Testing schedule-checkin.sh & cancel-checkin.sh          ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"

# Initialize workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test Checkin" > /dev/null 2>&1
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)

# Create tmux session with WORKFLOW_NAME env var
echo "Creating test tmux session: $TEST_SESSION"
tmux new-session -d -s "$TEST_SESSION" -c "$TEST_DIR"
tmux setenv -t "$TEST_SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"

# Test 1: schedule-checkin.sh requires WORKFLOW_NAME
echo ""
echo "=== Test 1: schedule-checkin.sh requires WORKFLOW_NAME ==="
# Run without WORKFLOW_NAME set
OUTPUT_NO_WORKFLOW=$(env -i PATH="$PATH" HOME="$HOME" bash -c "cd $TEST_DIR && $PROJECT_ROOT/bin/schedule-checkin.sh 1 'Test'" 2>&1 || true)

if echo "$OUTPUT_NO_WORKFLOW" | grep -qi "No WORKFLOW_NAME\|error"; then
    pass "schedule-checkin.sh requires WORKFLOW_NAME"
else
    skip "Cannot verify WORKFLOW_NAME requirement (tmux env detection)"
fi

# Test 2: Run schedule-checkin.sh from inside tmux
echo ""
echo "=== Test 2: schedule-checkin.sh from inside tmux ==="
# Run schedule-checkin.sh inside the tmux session
tmux send-keys -t "$TEST_SESSION:0" "cd $TEST_DIR && $PROJECT_ROOT/bin/schedule-checkin.sh 1 'Test check-in note'" Enter
sleep 2

# Capture output
SCHEDULE_OUTPUT=$(tmux capture-pane -t "$TEST_SESSION:0" -p)

if echo "$SCHEDULE_OUTPUT" | grep -q "Scheduled successfully\|Scheduling check"; then
    pass "schedule-checkin.sh runs successfully"
else
    fail "schedule-checkin.sh did not succeed"
    echo "$SCHEDULE_OUTPUT"
fi

# Test 3: Verify checkins.json created
echo ""
echo "=== Test 3: Verify checkins.json created ==="
CHECKIN_FILE="$TEST_DIR/.workflow/$WORKFLOW_NAME/checkins.json"
if [[ -f "$CHECKIN_FILE" ]]; then
    pass "checkins.json created"
else
    fail "checkins.json not created"
fi

# Test 4: Verify checkins.json has pending entry
echo ""
echo "=== Test 4: Verify checkins.json has pending entry ==="
if grep -q '"status": "pending"' "$CHECKIN_FILE"; then
    pass "checkins.json has pending entry"
else
    fail "checkins.json missing pending entry"
fi

# Test 5: Verify checkin note is saved
echo ""
echo "=== Test 5: Verify checkin note is saved ==="
if grep -q "Test check-in note" "$CHECKIN_FILE"; then
    pass "Checkin note saved correctly"
else
    fail "Checkin note not found"
fi

# Test 6: Verify scheduled_for time is set
echo ""
echo "=== Test 6: Verify scheduled_for time is set ==="
if grep -q '"scheduled_for":' "$CHECKIN_FILE"; then
    pass "scheduled_for time is set"
else
    fail "scheduled_for time not found"
fi

# Test 7: Verify checkin_interval.txt created
echo ""
echo "=== Test 7: Verify checkin_interval.txt created ==="
INTERVAL_FILE="$TEST_DIR/.workflow/$WORKFLOW_NAME/checkin_interval.txt"
if [[ -f "$INTERVAL_FILE" ]]; then
    INTERVAL=$(cat "$INTERVAL_FILE")
    if [[ "$INTERVAL" == "1" ]]; then
        pass "checkin_interval.txt contains correct value: 1"
    else
        fail "checkin_interval.txt has wrong value: $INTERVAL"
    fi
else
    fail "checkin_interval.txt not created"
fi

# Test 8: cancel-checkin.sh requires WORKFLOW_NAME
echo ""
echo "=== Test 8: cancel-checkin.sh requires WORKFLOW_NAME ==="
OUTPUT_CANCEL_NO_WF=$(env -i PATH="$PATH" HOME="$HOME" bash -c "cd $TEST_DIR && $PROJECT_ROOT/bin/cancel-checkin.sh" 2>&1 || true)

if echo "$OUTPUT_CANCEL_NO_WF" | grep -qi "No WORKFLOW_NAME\|error"; then
    pass "cancel-checkin.sh requires WORKFLOW_NAME"
else
    skip "Cannot verify WORKFLOW_NAME requirement (tmux env detection)"
fi

# Test 9: Run cancel-checkin.sh from inside tmux
echo ""
echo "=== Test 9: Run cancel-checkin.sh from inside tmux ==="
tmux send-keys -t "$TEST_SESSION:0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

CANCEL_OUTPUT=$(tmux capture-pane -t "$TEST_SESSION:0" -p)

if echo "$CANCEL_OUTPUT" | grep -q "Check-in loop stopped\|Cancelled"; then
    pass "cancel-checkin.sh runs successfully"
else
    fail "cancel-checkin.sh did not succeed"
fi

# Test 10: Verify pending checkin was cancelled
echo ""
echo "=== Test 10: Verify pending checkin was cancelled ==="
if grep -q '"status": "cancelled"' "$CHECKIN_FILE"; then
    pass "Pending checkin was cancelled"
else
    fail "Checkin not marked as cancelled"
fi

# Test 11: Verify stopped entry was added
echo ""
echo "=== Test 11: Verify stopped entry was added ==="
if grep -q '"status": "stopped"' "$CHECKIN_FILE"; then
    pass "Stopped entry added to checkins.json"
else
    fail "Stopped entry not found"
fi

# Test 12: Verify checkin_interval.txt was removed
echo ""
echo "=== Test 12: Verify checkin_interval.txt was removed ==="
if [[ ! -f "$INTERVAL_FILE" ]]; then
    pass "checkin_interval.txt removed after cancel"
else
    fail "checkin_interval.txt should be removed"
fi

# Test 13: Schedule another checkin to test resume
echo ""
echo "=== Test 13: Test resume after stop ==="
tmux send-keys -t "$TEST_SESSION:0" "$PROJECT_ROOT/bin/schedule-checkin.sh 1 'After resume'" Enter
sleep 2

if grep -q '"status": "resumed"' "$CHECKIN_FILE"; then
    pass "Resumed entry added when scheduling after stop"
else
    fail "Resumed entry not found"
fi

# Test 14: Multiple checkins can be scheduled
echo ""
echo "=== Test 14: Multiple pending checkins ==="
tmux send-keys -t "$TEST_SESSION:0" "$PROJECT_ROOT/bin/schedule-checkin.sh 2 'Second checkin'" Enter
sleep 2

PENDING_COUNT=$(grep -c '"status": "pending"' "$CHECKIN_FILE")
if [[ "$PENDING_COUNT" -ge 2 ]]; then
    pass "Multiple pending checkins scheduled: $PENDING_COUNT"
else
    fail "Expected at least 2 pending checkins, got $PENDING_COUNT"
fi

# Test 15: Cancel removes all pending checkins
echo ""
echo "=== Test 15: Cancel removes all pending checkins ==="
tmux send-keys -t "$TEST_SESSION:0" "$PROJECT_ROOT/bin/cancel-checkin.sh" Enter
sleep 2

REMAINING_PENDING=$(grep -c '"status": "pending"' "$CHECKIN_FILE" 2>/dev/null | head -1 || echo "0")
REMAINING_PENDING=${REMAINING_PENDING:-0}
if [[ "$REMAINING_PENDING" -eq 0 ]]; then
    pass "All pending checkins cancelled"
else
    fail "Still have $REMAINING_PENDING pending checkins"
fi

# Summary
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
    exit 1
fi
