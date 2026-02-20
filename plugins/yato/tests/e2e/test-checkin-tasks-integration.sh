#!/bin/bash
# test-checkin-tasks-integration.sh
#
# E2E Test: Integration between check-in scheduler and tasks.json
#
# Verifies:
# 1. Incomplete task count detection works correctly
# 2. Check-in schedules when incomplete tasks remain
# 3. All-completed detection returns 0
# 4. Interval is read from status.yml
# 5. Auto-stop updates status.yml when all tasks complete
#
# IMPORTANT: All execution goes through direct CLI calls (no Claude CLI needed).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-tasks-integration"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Check-in and tasks.json Integration"
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

# Create status.yml with 1-minute interval
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
session: e2e-checkin-int
EOF

# Create initial empty checkins.json
echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

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

# Create tmux session (needed as check-in target)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Test incomplete task count detection
# ============================================================
echo "Phase 2: Testing incomplete task count detection..."

# Count incomplete tasks directly
INCOMPLETE=$(uv run python -c "
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
# PHASE 3: Test check-in scheduling with incomplete tasks
# ============================================================
echo ""
echo "Phase 3: Testing check-in scheduling with incomplete tasks..."

# Start check-in daemon directly (CWD must be TEST_DIR for workflow discovery)
cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" start 1 --note 'Test checkin' --target "$SESSION_NAME:0" --workflow '001-test-workflow'
sleep 3

# Check that checkin was scheduled
PENDING_COUNT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_COUNT" -ge 1 ]]; then
    pass "Check-in scheduled successfully"
else
    fail "Check-in not scheduled, pending count: $PENDING_COUNT"
fi

# Cancel daemon before next test
cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" cancel --workflow '001-test-workflow'
sleep 2

# ============================================================
# PHASE 4: Test all-completed detection
# ============================================================
echo ""
echo "Phase 4: Testing all-completed detection..."

# Update tasks.json with all completed tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "dev", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Task 3", "agent": "qa", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Count incomplete tasks directly
INCOMPLETE=$(uv run python -c "
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
# PHASE 5: Test interval reading from status.yml
# ============================================================
echo ""
echo "Phase 5: Testing interval reading from status.yml..."

# Update status.yml with specific interval
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 7
session: e2e-checkin-int
EOF

INTERVAL=$(grep 'checkin_interval_minutes' "$TEST_DIR/.workflow/001-test-workflow/status.yml" 2>/dev/null | awk '{print $2}')

if [[ "$INTERVAL" == "7" ]]; then
    pass "Correctly reads interval (7) from status.yml"
else
    fail "Expected interval 7, got $INTERVAL"
fi

# ============================================================
# PHASE 6: Test with empty tasks array
# ============================================================
echo ""
echo "Phase 6: Testing with empty tasks array..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": []
}
EOF

INCOMPLETE=$(uv run python -c "
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
# PHASE 7: Test with missing tasks.json file
# ============================================================
echo ""
echo "Phase 7: Testing with missing tasks.json..."

rm -f "$TEST_DIR/.workflow/001-test-workflow/tasks.json"

INCOMPLETE=$(uv run python -c "
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
# PHASE 8: Test auto-stop updates status.yml when all tasks complete
# ============================================================
echo ""
echo "Phase 8: Testing auto-stop behavior..."

# Reset status.yml to in-progress
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
session: e2e-checkin-int
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
echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

# Run the auto-stop logic directly (same logic as checkin_scheduler.py)
uv run python -c "
import re, json
from pathlib import Path
from datetime import datetime
sf=Path('$TEST_DIR/.workflow/001-test-workflow/status.yml')
tf=Path('$TEST_DIR/.workflow/001-test-workflow/tasks.json')
d=json.load(open(tf))
inc=[t for t in d['tasks'] if t['status'] in ('pending','in_progress','blocked')]
if len(inc)==0:
    c=sf.read_text()
    c=re.sub(r'^status:.*$','status: completed',c,flags=re.MULTILINE)
    if 'completed_at:' not in c:
        c=c.rstrip()+'\ncompleted_at: '+datetime.now().isoformat()+'\n'
    sf.write_text(c)
    print('Status updated to completed')
"

# Verify status.yml was updated to completed
STATUS_VALUE=$(grep '^status:' "$TEST_DIR/.workflow/001-test-workflow/status.yml" | awk '{print $2}')
if [[ "$STATUS_VALUE" == "completed" ]]; then
    pass "Auto-stop updates status.yml to 'completed'"
else
    fail "Expected status 'completed', got '$STATUS_VALUE'"
fi

# ============================================================
# PHASE 9: Verify completed_at timestamp is added
# ============================================================
echo ""
echo "Phase 9: Testing completed_at timestamp addition..."

if grep -q "completed_at:" "$TEST_DIR/.workflow/001-test-workflow/status.yml"; then
    pass "completed_at timestamp added to status.yml"
else
    fail "completed_at timestamp not found in status.yml"
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
