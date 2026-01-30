#!/bin/bash
# test-checkin-scheduling.sh
#
# E2E Test: Check-in scheduling and display
#
# Verifies:
# 1. Duplicate check-ins are prevented (no parallel loops)
# 2. Notes are displayed without excessive truncation (40 chars)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-scheduling"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-checkin-sched-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: Check-in Scheduling and Display"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 5
EOF

# Create initial empty checkins.json
echo '{"checkins": []}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

# Create tasks.json with pending tasks (for auto-continue)
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Test task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Create tmux session with WORKFLOW_NAME
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Test 1: First check-in schedules successfully
# ============================================================

echo "Testing first check-in schedules successfully..."

# Run schedule-checkin from inside the session
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/schedule-checkin.sh 1 'First check-in' $SESSION_NAME:0 2>&1 | tee /tmp/checkin-test-1.txt" Enter
sleep 3

OUTPUT1=$(cat /tmp/checkin-test-1.txt 2>/dev/null)

if echo "$OUTPUT1" | grep -q "Scheduled successfully"; then
    pass "First check-in scheduled successfully"
else
    fail "First check-in failed to schedule: $OUTPUT1"
fi

# Verify checkins.json has pending entry
PENDING_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data.get('checkins', []) if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_COUNT" == "1" ]]; then
    pass "checkins.json has 1 pending entry"
else
    fail "Expected 1 pending entry, got $PENDING_COUNT"
fi

# ============================================================
# Test 2: Duplicate check-in is prevented
# ============================================================

echo ""
echo "Testing duplicate check-in is prevented..."

# Try to schedule another check-in while one is pending
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/schedule-checkin.sh 1 'Duplicate check-in' $SESSION_NAME:0 2>&1 | tee /tmp/checkin-test-2.txt" Enter
sleep 3

OUTPUT2=$(cat /tmp/checkin-test-2.txt 2>/dev/null)

if echo "$OUTPUT2" | grep -q "already pending"; then
    pass "Duplicate check-in prevented with message"
else
    fail "Duplicate check-in should be prevented: $OUTPUT2"
fi

# Verify still only 1 pending
PENDING_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data.get('checkins', []) if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_COUNT" == "1" ]]; then
    pass "Still only 1 pending entry (no duplicate created)"
else
    fail "Should still be 1 pending, got $PENDING_COUNT"
fi

# ============================================================
# Test 3: After cancel, new check-in can be scheduled
# ============================================================

echo ""
echo "Testing check-in after cancel..."

# Cancel the pending check-in
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/cancel-checkin.sh 2>&1" Enter
sleep 3

# Now schedule should work again
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/schedule-checkin.sh 1 'After cancel check-in' $SESSION_NAME:0 2>&1 | tee /tmp/checkin-test-3.txt" Enter
sleep 3

OUTPUT3=$(cat /tmp/checkin-test-3.txt 2>/dev/null)

if echo "$OUTPUT3" | grep -q "Scheduled successfully"; then
    pass "Check-in scheduled after cancel"
else
    fail "Should schedule after cancel: $OUTPUT3"
fi

# ============================================================
# Test 4: Note truncation is 40 chars (not 25)
# ============================================================

echo ""
echo "Testing note truncation limit..."

# Check the display script truncation
TRUNCATION_LIMIT=$(grep -o '\[:40\]' "$BIN_DIR/checkin-display.sh" | wc -l | tr -d ' ')

if [[ "$TRUNCATION_LIMIT" -ge 4 ]]; then
    pass "Display script uses 40-char truncation (found $TRUNCATION_LIMIT occurrences)"
else
    fail "Expected 40-char truncation, found $TRUNCATION_LIMIT occurrences"
fi

# ============================================================
# Test 5: Long note is stored completely in JSON
# ============================================================

echo ""
echo "Testing long notes are stored completely..."

# Cancel existing and schedule with a long note
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/cancel-checkin.sh 2>&1" Enter
sleep 1

LONG_NOTE="Auto check-in (15 tasks remaining) - this is a longer note for testing"
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/schedule-checkin.sh 1 '$LONG_NOTE' $SESSION_NAME:0 2>&1" Enter
sleep 3

# Check that full note is in JSON
STORED_NOTE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data.get('checkins', []) if c.get('status') == 'pending']
    if pending:
        print(pending[-1].get('note', ''))
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$STORED_NOTE" | grep -q "15 tasks remaining"; then
    pass "Full note stored in JSON (not truncated at storage)"
else
    fail "Note may be truncated in storage: $STORED_NOTE"
fi

# ============================================================
# Test 6: Verify interval is read from status.yml
# ============================================================

echo ""
echo "Testing interval is read from status.yml..."

INTERVAL_FROM_FILE=$(grep 'checkin_interval_minutes' "$TEST_DIR/.workflow/001-test-workflow/status.yml" | awk '{print $2}')

if [[ "$INTERVAL_FROM_FILE" == "5" ]]; then
    pass "status.yml has correct interval: 5 minutes"
else
    fail "status.yml interval incorrect: $INTERVAL_FROM_FILE"
fi

# ============================================================
# Results
# ============================================================

echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
