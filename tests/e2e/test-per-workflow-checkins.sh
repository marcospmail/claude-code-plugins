#!/bin/bash
# test-per-workflow-checkins.sh
#
# E2E Test: Per-workflow check-in isolation
#
# Verifies that check-ins are stored per-workflow and don't interfere
# with each other across different projects/workflows.
# Scripts read WORKFLOW_NAME from tmux session environment variable.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="per-workflow-checkins"
TEST_ID="$$"
TEST_DIR_A="/tmp/e2e-test-$TEST_NAME-A-$TEST_ID"
TEST_DIR_B="/tmp/e2e-test-$TEST_NAME-B-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_A="e2e-wf-a-$TEST_ID"
SESSION_B="e2e-wf-b-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: Per-workflow check-in isolation (tmux env var)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_A" 2>/dev/null || true
    tmux kill-session -t "$SESSION_B" 2>/dev/null || true
    rm -rf "$TEST_DIR_A" "$TEST_DIR_B" 2>/dev/null || true
    # Kill any pending check-in background processes
    pkill -f "schedule-checkin.*$TEST_DIR_A" 2>/dev/null || true
    pkill -f "schedule-checkin.*$TEST_DIR_B" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create two test projects with workflows and tmux sessions
# ============================================================

mkdir -p "$TEST_DIR_A/.workflow/001-workflow-a"
mkdir -p "$TEST_DIR_B/.workflow/001-workflow-b"

# Create tasks.json with pending tasks
cat > "$TEST_DIR_A/.workflow/001-workflow-a/tasks.json" << 'EOF'
{"tasks": [{"id": "T1", "subject": "Task A1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []}], "metadata": {}}
EOF

cat > "$TEST_DIR_B/.workflow/001-workflow-b/tasks.json" << 'EOF'
{"tasks": [{"id": "T1", "subject": "Task B1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []}], "metadata": {}}
EOF

# Create status.yml
cat > "$TEST_DIR_A/.workflow/001-workflow-a/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

cat > "$TEST_DIR_B/.workflow/001-workflow-b/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 2
EOF

# Create tmux sessions with WORKFLOW_NAME env var
tmux new-session -d -s "$SESSION_A" -c "$TEST_DIR_A"
tmux setenv -t "$SESSION_A" WORKFLOW_NAME "001-workflow-a"

tmux new-session -d -s "$SESSION_B" -c "$TEST_DIR_B"
tmux setenv -t "$SESSION_B" WORKFLOW_NAME "001-workflow-b"

echo "Test directories created:"
echo "  Project A: $TEST_DIR_A (session: $SESSION_A)"
echo "  Project B: $TEST_DIR_B (session: $SESSION_B)"
echo ""

# ============================================================
# Test 1: Check-ins create workflow-specific files
# ============================================================

echo "Testing check-in file location..."

# Run schedule-checkin.sh inside tmux sessions
tmux send-keys -t "$SESSION_A" "cd $TEST_DIR_A && $BIN_DIR/schedule-checkin.sh 5 'Test A' '$SESSION_A:0'" Enter
sleep 3

tmux send-keys -t "$SESSION_B" "cd $TEST_DIR_B && $BIN_DIR/schedule-checkin.sh 5 'Test B' '$SESSION_B:0'" Enter
sleep 3

if [[ -f "$TEST_DIR_A/.workflow/001-workflow-a/checkins.json" ]]; then
    pass "Project A checkins.json created in workflow directory"
else
    fail "Project A checkins.json NOT in workflow directory"
fi

if [[ -f "$TEST_DIR_B/.workflow/001-workflow-b/checkins.json" ]]; then
    pass "Project B checkins.json created in workflow directory"
else
    fail "Project B checkins.json NOT in workflow directory"
fi

# ============================================================
# Test 2: Verify check-ins have correct content
# ============================================================

echo ""
echo "Testing check-in content..."

COUNT_A=$(python3 -c "
import json
with open('$TEST_DIR_A/.workflow/001-workflow-a/checkins.json') as f:
    d = json.load(f)
print(len([c for c in d['checkins'] if c.get('status')=='pending']))
" 2>/dev/null)

COUNT_B=$(python3 -c "
import json
with open('$TEST_DIR_B/.workflow/001-workflow-b/checkins.json') as f:
    d = json.load(f)
print(len([c for c in d['checkins'] if c.get('status')=='pending']))
" 2>/dev/null)

if [[ "$COUNT_A" == "1" ]]; then
    pass "Project A has 1 pending check-in"
else
    fail "Project A pending count wrong (expected 1, got $COUNT_A)"
fi

if [[ "$COUNT_B" == "1" ]]; then
    pass "Project B has 1 pending check-in"
else
    fail "Project B pending count wrong (expected 1, got $COUNT_B)"
fi

# ============================================================
# Test 3: Cancel only affects target project
# ============================================================

echo ""
echo "Testing cancel isolation..."

# Cancel from Project A session
tmux send-keys -t "$SESSION_A" "$BIN_DIR/cancel-checkin.sh" Enter
sleep 2

# Check Project A is cancelled
STATUS_A=$(python3 -c "
import json
with open('$TEST_DIR_A/.workflow/001-workflow-a/checkins.json') as f:
    d = json.load(f)
statuses = [c.get('status') for c in d['checkins']]
print('stopped' if 'stopped' in statuses else 'no-stop')
" 2>/dev/null)

if [[ "$STATUS_A" == "stopped" ]]; then
    pass "Project A has 'stopped' entry after cancel"
else
    fail "Project A missing 'stopped' entry after cancel"
fi

# Check Project B still has pending
PENDING_B=$(python3 -c "
import json
with open('$TEST_DIR_B/.workflow/001-workflow-b/checkins.json') as f:
    d = json.load(f)
print(len([c for c in d['checkins'] if c.get('status')=='pending']))
" 2>/dev/null)

if [[ "$PENDING_B" == "1" ]]; then
    pass "Project B still has pending check-in (not affected by Project A cancel)"
else
    fail "Project B pending count changed after Project A cancel (expected 1, got $PENDING_B)"
fi

# Check Project B has no stopped entry
STOPPED_B=$(python3 -c "
import json
with open('$TEST_DIR_B/.workflow/001-workflow-b/checkins.json') as f:
    d = json.load(f)
print(len([c for c in d['checkins'] if c.get('status')=='stopped']))
" 2>/dev/null)

if [[ "$STOPPED_B" == "0" ]]; then
    pass "Project B has no 'stopped' entry (isolated from Project A)"
else
    fail "Project B incorrectly has 'stopped' entry"
fi

# ============================================================
# Test 4: Interval file is workflow-specific
# ============================================================

echo ""
echo "Testing interval file location..."

if [[ -f "$TEST_DIR_B/.workflow/001-workflow-b/checkin_interval.txt" ]]; then
    INTERVAL_B=$(cat "$TEST_DIR_B/.workflow/001-workflow-b/checkin_interval.txt")
    if [[ "$INTERVAL_B" == "5" ]]; then
        pass "Project B interval file in workflow directory with correct value"
    else
        fail "Project B interval file has wrong value (expected 5, got $INTERVAL_B)"
    fi
else
    fail "Project B interval file NOT in workflow directory"
fi

# ============================================================
# Test 5: Error when WORKFLOW_NAME not set
# ============================================================

echo ""
echo "Testing error handling..."

# Create a session without WORKFLOW_NAME
TEST_SESSION="e2e-no-workflow-$TEST_ID"
TEST_DIR_NO_WF="/tmp/e2e-no-workflow-$TEST_ID"
mkdir -p "$TEST_DIR_NO_WF"

tmux new-session -d -s "$TEST_SESSION" -c "$TEST_DIR_NO_WF"
# Do NOT set WORKFLOW_NAME

tmux send-keys -t "$TEST_SESSION" "$BIN_DIR/schedule-checkin.sh 5 'Test' '$TEST_SESSION:0' 2>&1; echo DONE" Enter
sleep 3

ERROR_OUTPUT=$(tmux capture-pane -t "$TEST_SESSION" -p)
tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
rm -rf "$TEST_DIR_NO_WF"

if echo "$ERROR_OUTPUT" | grep -q "No WORKFLOW_NAME set"; then
    pass "Script errors when WORKFLOW_NAME not set"
else
    fail "Script should error when WORKFLOW_NAME not set"
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
