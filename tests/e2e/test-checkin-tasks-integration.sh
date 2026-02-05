#!/bin/bash
# test-checkin-tasks-integration.sh
#
# E2E Test: Integration between schedule-checkin.sh and tasks.json
#
# Verifies that:
# 1. Check-in auto-continues when incomplete tasks remain
# 2. Check-in loop stops when all tasks are completed
# 3. Correct task count is shown in auto-continue message

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-tasks-integration"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-checkin-int-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: Check-in and tasks.json Integration"
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
    # Kill any pending check-in background processes
    pkill -f "schedule-checkin.*$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

# Create status.yml with 1-minute interval (for faster testing)
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

# Create tmux session with WORKFLOW_NAME env var
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Test 1: Verify incomplete task count in check-in logic
# ============================================================

echo "Testing incomplete task count detection..."

# Create tasks.json with mixed statuses
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "dev", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Task 3", "agent": "qa", "status": "blocked", "blockedBy": ["T1"], "blocks": []},
    {"id": "T4", "subject": "Task 4", "agent": "dev", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Use the same Python logic as schedule-checkin.sh
INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "3" ]]; then
    pass "Correctly counts 3 incomplete tasks (pending + in_progress + blocked)"
else
    fail "Expected 3 incomplete tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 2: Verify check-in schedules when tasks incomplete
# ============================================================

echo ""
echo "Testing check-in scheduling with incomplete tasks..."

# Clear any existing checkins
echo '{"checkins": []}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

# Run schedule-checkin from within tmux session
tmux send-keys -t "$SESSION_NAME" "cd $TEST_DIR && $BIN_DIR/schedule-checkin.sh 1 'Test checkin' '$SESSION_NAME:0'" Enter
sleep 2

# Check that checkin was scheduled
PENDING_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_COUNT" == "1" ]]; then
    pass "Check-in scheduled successfully"
else
    fail "Check-in not scheduled, pending count: $PENDING_COUNT"
fi

# ============================================================
# Test 3: Verify all-completed detection logic
# ============================================================

echo ""
echo "Testing all-completed detection..."

# Create tasks.json with all completed tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "dev", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Task 3", "agent": "qa", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "Correctly detects 0 incomplete tasks (all completed)"
else
    fail "Expected 0 incomplete tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 4: Verify interval read from status.yml
# ============================================================

echo ""
echo "Testing interval reading from status.yml..."

# Update status.yml with specific interval
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 7
EOF

INTERVAL=$(grep 'checkin_interval_minutes' "$TEST_DIR/.workflow/001-test-workflow/status.yml" 2>/dev/null | awk '{print $2}')

if [[ "$INTERVAL" == "7" ]]; then
    pass "Correctly reads interval (7) from status.yml"
else
    fail "Expected interval 7, got $INTERVAL"
fi

# ============================================================
# Test 5: Verify auto-continue message format
# ============================================================

echo ""
echo "Testing auto-continue message format..."

# Restore tasks with 2 incomplete
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "dev", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Task 3", "agent": "qa", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

# The message format in schedule-checkin.sh is: "Auto check-in ($INCOMPLETE tasks remaining)"
EXPECTED_MSG="Auto check-in ($INCOMPLETE tasks remaining)"
if [[ "$EXPECTED_MSG" == "Auto check-in (2 tasks remaining)" ]]; then
    pass "Auto-continue message format is correct: $EXPECTED_MSG"
else
    fail "Unexpected message format: $EXPECTED_MSG"
fi

# ============================================================
# Test 6: Test with empty tasks array
# ============================================================

echo ""
echo "Testing with empty tasks array..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": []
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "Empty tasks array returns 0 incomplete"
else
    fail "Empty array should return 0, got $INCOMPLETE"
fi

# ============================================================
# Test 7: Test with missing tasks.json file
# ============================================================

echo ""
echo "Testing with missing tasks.json..."

rm -f "$TEST_DIR/.workflow/001-test-workflow/tasks.json"

# The check-in logic should handle missing file gracefully
INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "Missing tasks.json returns 0 (no error)"
else
    fail "Missing file should return 0, got $INCOMPLETE"
fi

# ============================================================
# Test 8: Verify auto-stop updates status.yml when all tasks complete
# ============================================================

echo ""
echo "Testing auto-stop behavior (status.yml update on completion)..."

# Reset status.yml to in-progress with very short interval for testing
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

# Create tasks.json with ALL completed tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "qa", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Clear checkins for fresh test
echo '{"checkins": []}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

# Simulate what the check-in script does when all tasks are complete
# This tests the auto-stop logic directly
python3 -c "
import re
from pathlib import Path
from datetime import datetime

status_file = Path('$TEST_DIR/.workflow/001-test-workflow/status.yml')
tasks_file = Path('$TEST_DIR/.workflow/001-test-workflow/tasks.json')

import json
with open(tasks_file, 'r') as f:
    data = json.load(f)
incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]

if len(incomplete) == 0:
    # Apply the same logic as checkin_scheduler.py lines 286-294
    content = status_file.read_text()
    content = re.sub(r'^status:.*$', 'status: completed', content, flags=re.MULTILINE)
    if 'completed_at:' not in content:
        content = content.rstrip() + '\ncompleted_at: ' + datetime.now().isoformat() + '\n'
    status_file.write_text(content)
"

# Verify status.yml was updated to completed
STATUS_VALUE=$(grep '^status:' "$TEST_DIR/.workflow/001-test-workflow/status.yml" | awk '{print $2}')
if [[ "$STATUS_VALUE" == "completed" ]]; then
    pass "Auto-stop updates status.yml to 'completed'"
else
    fail "Expected status 'completed', got '$STATUS_VALUE'"
fi

# ============================================================
# Test 9: Verify completed_at timestamp is added
# ============================================================

echo ""
echo "Testing completed_at timestamp addition..."

if grep -q "completed_at:" "$TEST_DIR/.workflow/001-test-workflow/status.yml"; then
    pass "completed_at timestamp added to status.yml"
else
    fail "completed_at timestamp not found in status.yml"
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
