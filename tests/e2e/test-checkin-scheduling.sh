#!/bin/bash
# test-checkin-scheduling.sh
#
# E2E Test: Check-in daemon scheduling and control
#
# Verifies:
# 1. Daemon starts with correct PID stored in checkins.json
# 2. Duplicate daemon starts are prevented
# 3. Daemon can be cancelled by killing the PID
# 4. After cancel, new daemon can be started
# 5. Notes are displayed without excessive truncation (40 chars)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-scheduling"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
LIB_DIR="$PROJECT_ROOT/lib"
SESSION_NAME="e2e-checkin-sched-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Check-in Daemon Scheduling"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes for this test
    if [[ -f "$TEST_DIR/.workflow/001-test-workflow/checkins.json" ]]; then
        PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        print(pid)
except:
    pass
" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
session: e2e-checkin-sched
EOF

# Create initial empty checkins.json
echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

# Create tasks.json with pending tasks (for auto-continue)
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Test task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Create tmux session with WORKFLOW_NAME
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Test 1: First daemon starts successfully with PID stored
# ============================================================

echo "Testing first daemon starts successfully..."

# Run schedule-checkin from inside the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $BIN_DIR/schedule-checkin.sh 1 'First check-in' $SESSION_NAME:0 2>&1 | tee /tmp/checkin-test-1.txt" Enter
sleep 3

OUTPUT1=$(cat /tmp/checkin-test-1.txt 2>/dev/null)

if echo "$OUTPUT1" | grep -q "Daemon started with PID"; then
    pass "Daemon started successfully"
else
    fail "Daemon failed to start: $OUTPUT1"
fi

# Verify daemon_pid is stored in checkins.json
DAEMON_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    print(pid if pid else '')
except:
    pass
" 2>/dev/null)

if [[ -n "$DAEMON_PID" ]]; then
    pass "Daemon PID stored in checkins.json: $DAEMON_PID"
else
    fail "Daemon PID not stored in checkins.json"
fi

# Verify the PID is actually running
if kill -0 "$DAEMON_PID" 2>/dev/null; then
    pass "Daemon process is running (PID $DAEMON_PID)"
else
    fail "Daemon process is not running"
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
# Test 2: Duplicate daemon start is prevented
# ============================================================

echo ""
echo "Testing duplicate daemon start is prevented..."

# Try to start another daemon while one is running
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $BIN_DIR/schedule-checkin.sh 1 'Duplicate check-in' $SESSION_NAME:0 2>&1 | tee /tmp/checkin-test-2.txt" Enter
sleep 3

OUTPUT2=$(cat /tmp/checkin-test-2.txt 2>/dev/null)

if echo "$OUTPUT2" | grep -q "already running"; then
    pass "Duplicate daemon prevented with message"
else
    fail "Duplicate daemon should be prevented: $OUTPUT2"
fi

# Verify still same PID
NEW_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    print(data.get('daemon_pid', ''))
except:
    pass
" 2>/dev/null)

if [[ "$NEW_PID" == "$DAEMON_PID" ]]; then
    pass "Same daemon PID (no new process started)"
else
    fail "PID changed from $DAEMON_PID to $NEW_PID"
fi

# ============================================================
# Test 3: Daemon can be cancelled (PID killed)
# ============================================================

echo ""
echo "Testing daemon cancellation..."

# Cancel the daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $BIN_DIR/cancel-checkin.sh 2>&1 | tee /tmp/checkin-test-3.txt" Enter
sleep 3

OUTPUT3=$(cat /tmp/checkin-test-3.txt 2>/dev/null)

if echo "$OUTPUT3" | grep -q "stopped"; then
    pass "Cancel command reports stopped"
else
    fail "Cancel should report stopped: $OUTPUT3"
fi

# Verify the process is killed
if kill -0 "$DAEMON_PID" 2>/dev/null; then
    fail "Daemon process still running after cancel"
else
    pass "Daemon process killed"
fi

# Verify daemon_pid is cleared
CLEARED_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    print(data.get('daemon_pid', 'NONE'))
except:
    pass
" 2>/dev/null)

if [[ "$CLEARED_PID" == "None" ]] || [[ "$CLEARED_PID" == "NONE" ]] || [[ -z "$CLEARED_PID" ]]; then
    pass "Daemon PID cleared from checkins.json"
else
    fail "Daemon PID not cleared: $CLEARED_PID"
fi

# Verify stopped entry added
STOPPED_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    stopped = [c for c in data.get('checkins', []) if c.get('status') == 'stopped']
    print(len(stopped))
except:
    print(0)
" 2>/dev/null)

if [[ "$STOPPED_COUNT" -ge 1 ]]; then
    pass "Stopped entry added to checkins.json"
else
    fail "No stopped entry found"
fi

# ============================================================
# Test 4: After cancel, new daemon can be started
# ============================================================

echo ""
echo "Testing daemon start after cancel..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $BIN_DIR/schedule-checkin.sh 1 'After cancel check-in' $SESSION_NAME:0 2>&1 | tee /tmp/checkin-test-4.txt" Enter
sleep 3

OUTPUT4=$(cat /tmp/checkin-test-4.txt 2>/dev/null)

if echo "$OUTPUT4" | grep -q "Daemon started"; then
    pass "New daemon started after cancel"
else
    fail "Should start new daemon after cancel: $OUTPUT4"
fi

# Verify resumed entry added
RESUMED_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    resumed = [c for c in data.get('checkins', []) if c.get('status') == 'resumed']
    print(len(resumed))
except:
    print(0)
" 2>/dev/null)

if [[ "$RESUMED_COUNT" -ge 1 ]]; then
    pass "Resumed entry added when starting after cancel"
else
    fail "No resumed entry found"
fi

# ============================================================
# Test 5: Note truncation is 40 chars (not 25)
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
# Test 6: Long note is stored completely in JSON
# ============================================================

echo ""
echo "Testing long notes are stored completely..."

# Cancel existing and start with a long note
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $BIN_DIR/cancel-checkin.sh 2>&1" Enter
sleep 2

LONG_NOTE="Auto check-in (15 tasks remaining) - this is a longer note for testing"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $BIN_DIR/schedule-checkin.sh 1 '$LONG_NOTE' $SESSION_NAME:0 2>&1" Enter
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
# Test 7: Status command shows daemon info
# ============================================================

echo ""
echo "Testing status command..."

STATUS_OUTPUT=$(cd "$TEST_DIR" && python3 "$LIB_DIR/checkin_scheduler.py" status --workflow "001-test-workflow" 2>&1)

if echo "$STATUS_OUTPUT" | grep -q "Daemon running: True"; then
    pass "Status shows daemon running"
else
    fail "Status should show daemon running: $STATUS_OUTPUT"
fi

if echo "$STATUS_OUTPUT" | grep -q "Daemon PID:"; then
    pass "Status shows daemon PID"
else
    fail "Status should show daemon PID"
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
