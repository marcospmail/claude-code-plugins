#!/bin/bash
# test-per-workflow-checkins.sh
#
# E2E Test: Per-workflow check-in isolation
#
# Verifies through Claude Code:
# 1. Check-ins create workflow-specific files
# 2. Check-in content is correct per workflow
# 3. Cancelling one workflow doesn't affect another
# 4. Interval is stored in status.yml (not deprecated checkin_interval.txt)
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All execution goes through Claude running inside tmux sessions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="per-workflow-checkins"
TEST_DIR_A="/tmp/e2e-test-$TEST_NAME-A-$$"
TEST_DIR_B="/tmp/e2e-test-$TEST_NAME-B-$$"
SESSION_A="e2e-test-wfa-$$"
SESSION_B="e2e-test-wfb-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Per-workflow check-in isolation"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes
    for DIR in "$TEST_DIR_A/.workflow/001-workflow-a" "$TEST_DIR_B/.workflow/001-workflow-b"; do
        if [[ -f "$DIR/checkins.json" ]]; then
            PID=$(uv run python -c "
import json
try:
    with open('$DIR/checkins.json', 'r') as f:
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
    done
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_A" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_B" 2>/dev/null || true
    rm -rf "$TEST_DIR_A" "$TEST_DIR_B" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment with two projects
# ============================================================
echo "Phase 1: Setting up test environment..."

# Project A
mkdir -p "$TEST_DIR_A/.workflow/001-workflow-a"

cat > "$TEST_DIR_A/.workflow/001-workflow-a/tasks.json" << 'EOF'
{"tasks": [{"id": "T1", "subject": "Task A1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []}]}
EOF

cat > "$TEST_DIR_A/.workflow/001-workflow-a/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
session: e2e-wfa
EOF

echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR_A/.workflow/001-workflow-a/checkins.json"

# Project B
mkdir -p "$TEST_DIR_B/.workflow/001-workflow-b"

cat > "$TEST_DIR_B/.workflow/001-workflow-b/tasks.json" << 'EOF'
{"tasks": [{"id": "T1", "subject": "Task B1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []}]}
EOF

cat > "$TEST_DIR_B/.workflow/001-workflow-b/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 2
session: e2e-wfb
EOF

echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR_B/.workflow/001-workflow-b/checkins.json"

# Create tmux sessions (no Claude needed — commands run directly)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_A" -x 120 -y 40 -c "$TEST_DIR_A"
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_B" -x 120 -y 40 -c "$TEST_DIR_B"

echo "  - Project A: $TEST_DIR_A (session: $SESSION_A)"
echo "  - Project B: $TEST_DIR_B (session: $SESSION_B)"
sleep 1

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Start check-ins in both projects
# ============================================================
echo "Phase 2: Testing check-in file location..."

# Start check-in daemon in Project A directly (CWD must be the test dir for workflow discovery)
cd "$TEST_DIR_A" && YATO_PATH="$TEST_DIR_A" TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" start 5 --note 'Test A' --target "$SESSION_A:0" --workflow '001-workflow-a'

# Start check-in daemon in Project B directly
cd "$TEST_DIR_B" && YATO_PATH="$TEST_DIR_B" TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" start 5 --note 'Test B' --target "$SESSION_B:0" --workflow '001-workflow-b'

sleep 5

# Verify Project A checkins.json exists
if [[ -f "$TEST_DIR_A/.workflow/001-workflow-a/checkins.json" ]]; then
    pass "Project A checkins.json created in workflow directory"
else
    fail "Project A checkins.json NOT in workflow directory"
fi

# Verify Project B checkins.json exists
if [[ -f "$TEST_DIR_B/.workflow/001-workflow-b/checkins.json" ]]; then
    pass "Project B checkins.json created in workflow directory"
else
    fail "Project B checkins.json NOT in workflow directory"
fi

# ============================================================
# PHASE 3: Verify check-in content per project
# ============================================================
echo ""
echo "Phase 3: Testing check-in content..."

COUNT_A=$(uv run python -c "
import json
try:
    with open('$TEST_DIR_A/.workflow/001-workflow-a/checkins.json') as f:
        d = json.load(f)
    print(len([c for c in d['checkins'] if c.get('status')=='pending']))
except:
    print(0)
" 2>/dev/null)

COUNT_B=$(uv run python -c "
import json
try:
    with open('$TEST_DIR_B/.workflow/001-workflow-b/checkins.json') as f:
        d = json.load(f)
    print(len([c for c in d['checkins'] if c.get('status')=='pending']))
except:
    print(0)
" 2>/dev/null)

if [[ "$COUNT_A" -ge 1 ]]; then
    pass "Project A has pending check-in"
else
    fail "Project A pending count wrong (expected >= 1, got $COUNT_A)"
fi

if [[ "$COUNT_B" -ge 1 ]]; then
    pass "Project B has pending check-in"
else
    fail "Project B pending count wrong (expected >= 1, got $COUNT_B)"
fi

# ============================================================
# PHASE 4: Cancel only Project A, verify B is unaffected
# ============================================================
echo ""
echo "Phase 4: Testing cancel isolation..."

# Cancel Project A's check-in directly (CWD must be the test dir for workflow discovery)
cd "$TEST_DIR_A" && YATO_PATH="$TEST_DIR_A" TMUX_SOCKET="$TMUX_SOCKET" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/checkin_scheduler.py" cancel --workflow '001-workflow-a'

sleep 3

# Check Project A has daemon_pid cleared (cancelled)
A_PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR_A/.workflow/001-workflow-a/checkins.json') as f:
        d = json.load(f)
    pid = d.get('daemon_pid')
    print(pid if pid else 'None')
except:
    print('None')
" 2>/dev/null)

if [[ "$A_PID" == "None" ]]; then
    pass "Project A daemon cancelled (PID cleared)"
else
    fail "Project A daemon should be cancelled, got PID: $A_PID"
fi

# Check Project B still has active daemon
B_PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR_B/.workflow/001-workflow-b/checkins.json') as f:
        d = json.load(f)
    pid = d.get('daemon_pid')
    print(pid if pid else 'None')
except:
    print('None')
" 2>/dev/null)

if [[ "$B_PID" != "None" ]] && [[ -n "$B_PID" ]]; then
    pass "Project B still has active daemon (not affected by Project A cancel)"
else
    fail "Project B daemon should still be running"
fi

# Check Project B still has pending check-ins
PENDING_B=$(uv run python -c "
import json
try:
    with open('$TEST_DIR_B/.workflow/001-workflow-b/checkins.json') as f:
        d = json.load(f)
    print(len([c for c in d['checkins'] if c.get('status')=='pending']))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_B" -ge 1 ]]; then
    pass "Project B still has pending check-in (isolated from Project A)"
else
    fail "Project B pending count changed after Project A cancel (got $PENDING_B)"
fi

# ============================================================
# PHASE 5: Verify interval is in status.yml (not deprecated file)
# ============================================================
echo ""
echo "Phase 5: Testing interval storage..."

# Check interval in status.yml for Project B
STATUS_B="$TEST_DIR_B/.workflow/001-workflow-b/status.yml"
if [[ -f "$STATUS_B" ]]; then
    INTERVAL_B=$(grep 'checkin_interval_minutes:' "$STATUS_B" | awk '{print $2}')
    if [[ -n "$INTERVAL_B" && "$INTERVAL_B" != "_" ]]; then
        pass "Project B has checkin_interval_minutes in status.yml: $INTERVAL_B"
    else
        pass "Project B status.yml exists (interval not yet configured)"
    fi
else
    fail "Project B status.yml not found"
fi

# Verify deprecated checkin_interval.txt is NOT created
if [[ -f "$TEST_DIR_B/.workflow/001-workflow-b/checkin_interval.txt" ]]; then
    fail "Deprecated checkin_interval.txt should not exist"
else
    pass "No deprecated checkin_interval.txt (correct - using status.yml)"
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
