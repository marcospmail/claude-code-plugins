#!/bin/bash
# test-should-stop-task-completion.sh
#
# E2E Test: Daemon stops within polling interval when all tasks complete
#
# Verifies Bug 1 fix: should_stop() / polling loop now checks task completion
# every DAEMON_POLL_INTERVAL (10s) instead of only at check-in fire time.
#
# Tests:
# 1. Daemon starts and runs with incomplete tasks
# 2. When all tasks are marked completed, daemon stops within ~20 seconds
# 3. Daemon cleanup is correct: daemon_pid=null, pending cancelled, stopped entry added
# 4. status.yml updated to "completed"
# 5. Daemon does NOT stop when some tasks are still incomplete
#
# This test uses the Python API directly (no Claude/tmux needed).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="should-stop-task-completion"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: Daemon Stops on Task Completion (Bug 1 Fix)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

get_daemon_pid() {
    cd "$PROJECT_ROOT" && uv run python -c "
import json, os
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        try:
            os.kill(pid, 0)
            print(pid)
        except:
            print('')
    else:
        print('')
except:
    print('')
" 2>/dev/null
}

is_process_alive() {
    kill -0 "$1" 2>/dev/null
}

cleanup() {
    echo ""; echo "Cleaning up..."
    PID=$(get_daemon_pid)
    if [[ -n "$PID" ]]; then
        kill -9 "$PID" 2>/dev/null || true
    fi
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow
# ============================================================
echo "Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test"

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: fake-session
EOF

echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR/.workflow/001-test/checkins.json"

# Create tasks with 2 incomplete tasks
cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "qa", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

echo "  Test directory: $TEST_DIR"
echo ""

# ============================================================
# Test 1: Start daemon with incomplete tasks
# ============================================================
echo "Test 1: Starting daemon with incomplete tasks..."

cd "$PROJECT_ROOT" && uv run python -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT/lib')
from checkin_scheduler import CheckinScheduler
s = CheckinScheduler('$TEST_DIR/.workflow/001-test')
pid = s.start(
    interval_minutes=5,
    note='Test checkin',
    target='fake-session:0',
    yato_path='$PROJECT_ROOT',
)
print(f'PID:{pid}')
" 2>/dev/null

# Wait for daemon to register PID
sleep 2

DAEMON_PID=$(get_daemon_pid)

if [[ -n "$DAEMON_PID" ]]; then
    pass "Daemon started with PID: $DAEMON_PID"
else
    fail "Daemon did not start"
    exit 1
fi

# Verify daemon is actually alive
if is_process_alive "$DAEMON_PID"; then
    pass "Daemon process is alive"
else
    fail "Daemon process is not alive"
    exit 1
fi

# ============================================================
# Test 2: Daemon stays running with incomplete tasks
# ============================================================
echo ""
echo "Test 2: Daemon stays running with incomplete tasks..."

# Wait one full poll cycle (10s) + buffer
sleep 12

if is_process_alive "$DAEMON_PID"; then
    pass "Daemon still running after 12s (tasks still incomplete)"
else
    fail "Daemon stopped prematurely - tasks are still incomplete"
fi

# ============================================================
# Test 3: Complete one task - daemon should stay running (1 incomplete remains)
# ============================================================
echo ""
echo "Test 3: Complete one task - daemon should keep running..."

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "qa", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Wait one full poll cycle + buffer
sleep 12

if is_process_alive "$DAEMON_PID"; then
    pass "Daemon still running with 1 incomplete task"
else
    fail "Daemon stopped with 1 incomplete task remaining"
fi

# ============================================================
# Test 4: Complete ALL tasks - daemon should stop within ~20s
# ============================================================
echo ""
echo "Test 4: Complete all tasks - daemon should stop within polling interval..."

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "qa", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Wait for daemon to detect task completion
# DAEMON_POLL_INTERVAL is 10s, so wait up to 20s (2 poll cycles)
STOPPED=false
for i in 1 2 3 4; do
    sleep 5
    if ! is_process_alive "$DAEMON_PID"; then
        STOPPED=true
        STOP_TIME=$((i * 5))
        break
    fi
done

if [[ "$STOPPED" == "true" ]]; then
    pass "Daemon stopped within ${STOP_TIME}s of all tasks completing"
else
    fail "Daemon still running 20s after all tasks completed"
fi

# ============================================================
# Test 5: Verify daemon_pid cleared in checkins.json
# ============================================================
echo ""
echo "Test 5: Verifying cleanup state..."

FINAL_PID=$(cd "$PROJECT_ROOT" && uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    print(data.get('daemon_pid', 'NOT_NULL'))
except:
    print('ERROR')
" 2>/dev/null)

if [[ "$FINAL_PID" == "None" ]]; then
    pass "daemon_pid cleared to null in checkins.json"
else
    fail "daemon_pid should be null, got: $FINAL_PID"
fi

# ============================================================
# Test 6: Verify pending checkins were cancelled
# ============================================================
echo ""
echo "Test 6: Checking pending checkins were cancelled..."

CANCELLED_COUNT=$(cd "$PROJECT_ROOT" && uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    cancelled = [c for c in data.get('checkins', []) if c.get('status') == 'cancelled']
    print(len(cancelled))
except:
    print(0)
" 2>/dev/null)

if [[ "$CANCELLED_COUNT" -ge 1 ]]; then
    pass "Pending checkins were cancelled ($CANCELLED_COUNT cancelled entries)"
else
    fail "Expected cancelled checkin entries, got $CANCELLED_COUNT"
fi

# ============================================================
# Test 7: Verify stopped entry with "All tasks complete" reason
# ============================================================
echo ""
echo "Test 7: Checking stopped entry..."

STOPPED_NOTE=$(cd "$PROJECT_ROOT" && uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    stopped = [c for c in data.get('checkins', []) if c.get('status') == 'stopped']
    if stopped:
        print(stopped[-1].get('note', ''))
except:
    pass
" 2>/dev/null)

if echo "$STOPPED_NOTE" | grep -qi "all tasks complete"; then
    pass "Stopped entry has correct reason: '$STOPPED_NOTE'"
else
    fail "Stopped entry should mention 'All tasks complete', got: '$STOPPED_NOTE'"
fi

# ============================================================
# Test 8: Verify status.yml updated to completed
# ============================================================
echo ""
echo "Test 8: Checking status.yml..."

STATUS_VALUE=$(cd "$PROJECT_ROOT" && uv run python -c "
import yaml
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        data = yaml.safe_load(f)
    print(data.get('status', ''))
except:
    print('')
" 2>/dev/null)

if [[ "$STATUS_VALUE" == "completed" ]]; then
    pass "status.yml updated to 'completed'"
else
    fail "status.yml should be 'completed', got: '$STATUS_VALUE'"
fi

# Check completed_at timestamp exists
COMPLETED_AT=$(cd "$PROJECT_ROOT" && uv run python -c "
import yaml
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        data = yaml.safe_load(f)
    print(data.get('completed_at', ''))
except:
    print('')
" 2>/dev/null)

if [[ -n "$COMPLETED_AT" ]]; then
    pass "status.yml has completed_at timestamp: $COMPLETED_AT"
else
    fail "status.yml missing completed_at timestamp"
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
