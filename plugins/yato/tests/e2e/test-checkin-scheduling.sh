#!/bin/bash
# test-checkin-scheduling.sh
#
# E2E Test: Check-in daemon scheduling and control
#
# Verifies:
# 1. Daemon starts with correct PID stored in checkins.json
# 2. Duplicate daemon starts are prevented
# 3. Daemon can be cancelled
# 4. After cancel, new daemon can be started
# 5. Status command shows daemon info
#
# IMPORTANT: All execution goes through direct CLI calls (no Claude CLI needed).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-scheduling"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Check-in Daemon Scheduling"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes for this test
    if [[ -f "$TEST_DIR/.workflow/001-test-workflow/checkins.json" ]]; then
        PID=$(uv run python -c "
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
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

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

# Create tmux session (needed as check-in target)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Test daemon starts successfully with PID stored
# ============================================================
echo "Phase 2: Testing first daemon starts successfully..."

# Start check-in daemon directly (CWD must be TEST_DIR for workflow discovery)
cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" start 1 --note 'First check-in' --target "$SESSION_NAME:0" --workflow '001-test-workflow'
sleep 3

# Verify daemon_pid is stored in checkins.json
DAEMON_PID=$(uv run python -c "
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
if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    pass "Daemon process is running (PID $DAEMON_PID)"
else
    fail "Daemon process is not running"
fi

# Verify checkins.json has pending entry
PENDING_COUNT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data.get('checkins', []) if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_COUNT" -ge 1 ]]; then
    pass "checkins.json has pending entry"
else
    fail "Expected pending entry, got $PENDING_COUNT"
fi

# ============================================================
# PHASE 3: Test duplicate daemon start is prevented
# ============================================================
echo ""
echo "Phase 3: Testing duplicate daemon start is prevented..."

# Try to start another daemon while one is running - capture output
DUP_OUTPUT=$(cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" start 1 --note 'Duplicate check-in' --target "$SESSION_NAME:0" --workflow '001-test-workflow' 2>&1)
sleep 2

# Verify still same PID (no new process started)
NEW_PID=$(uv run python -c "
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

# Check output for "already running" message
if echo "$DUP_OUTPUT" | grep -qi "already running"; then
    pass "Duplicate daemon prevented with message"
else
    fail "Duplicate daemon should report 'already running' (output: $DUP_OUTPUT)"
fi

# ============================================================
# PHASE 4: Test daemon can be cancelled
# ============================================================
echo ""
echo "Phase 4: Testing daemon cancellation..."

# Cancel the daemon directly
cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" cancel --workflow '001-test-workflow'
sleep 2

# Verify the process is killed
if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    fail "Daemon process still running after cancel"
else
    pass "Daemon process killed"
fi

# Verify daemon_pid is cleared
CLEARED_PID=$(uv run python -c "
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

# ============================================================
# PHASE 5: After cancel, new daemon can be started
# ============================================================
echo ""
echo "Phase 5: Testing daemon start after cancel..."

cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" start 1 --note 'After cancel check-in' --target "$SESSION_NAME:0" --workflow '001-test-workflow'
sleep 3

# Verify new daemon started
NEW_DAEMON_PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    print(pid if pid else '')
except:
    pass
" 2>/dev/null)

if [[ -n "$NEW_DAEMON_PID" ]]; then
    pass "New daemon started after cancel (PID: $NEW_DAEMON_PID)"
else
    fail "No new daemon started after cancel"
fi

# ============================================================
# PHASE 6: Test status command shows daemon info
# ============================================================
echo ""
echo "Phase 6: Testing status command..."

STATUS_OUTPUT=$(cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" status --workflow '001-test-workflow' 2>&1)

if echo "$STATUS_OUTPUT" | grep -q "Daemon running: True"; then
    pass "Status shows daemon running"
else
    fail "Status should show daemon running (output: $STATUS_OUTPUT)"
fi

if echo "$STATUS_OUTPUT" | grep -q "Daemon PID:"; then
    pass "Status shows daemon PID"
else
    fail "Status should show daemon PID (output: $STATUS_OUTPUT)"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    EXIT_CODE=0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    EXIT_CODE=1
fi
echo "======================================================================"
echo ""

exit $EXIT_CODE
