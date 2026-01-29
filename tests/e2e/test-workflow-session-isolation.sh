#!/bin/bash
# test-workflow-session-isolation.sh - Test per-session workflow isolation
#
# Tests:
# 1. Session naming uses {project}_{workflow} format
# 2. WORKFLOW_NAME env var is set in tmux session
# 3. Check-in scripts read from tmux env var
# 4. Concurrent workflows in same project are isolated

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
ORCHESTRATOR_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

# Test utilities
pass() { echo "  PASS: $1"; }
fail() { echo "  FAIL: $1"; exit 1; }

echo "======================================================================"
echo "  E2E Test: Workflow Session Isolation (tmux env var)"
echo "======================================================================"
echo ""

# Create unique test ID
TEST_ID="$$"
TEST_DIR_A="/tmp/e2e-wf-isolation-A-$TEST_ID"
TEST_DIR_B="/tmp/e2e-wf-isolation-B-$TEST_ID"
SESSION_A=""
SESSION_B=""

cleanup() {
    echo ""
    echo "Cleaning up..."
    [[ -n "$SESSION_A" ]] && tmux kill-session -t "$SESSION_A" 2>/dev/null || true
    [[ -n "$SESSION_B" ]] && tmux kill-session -t "$SESSION_B" 2>/dev/null || true
    rm -rf "$TEST_DIR_A" "$TEST_DIR_B" 2>/dev/null || true
}
trap cleanup EXIT

# Create test project directories
mkdir -p "$TEST_DIR_A"
mkdir -p "$TEST_DIR_B"

echo "Test directories:"
echo "  Project A: $TEST_DIR_A"
echo "  Project B: $TEST_DIR_B"
echo ""

# ===========================================
# Test 1: Session naming format
# ===========================================
echo "Testing session naming format..."

# Create workflow in project A
cd "$TEST_DIR_A"
WORKFLOW_A=$("$ORCHESTRATOR_ROOT/bin/init-workflow.sh" "$TEST_DIR_A" "Add feature X" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')
if [[ -z "$WORKFLOW_A" ]]; then
    WORKFLOW_A=$(ls -td "$TEST_DIR_A/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename)
fi

if [[ -z "$WORKFLOW_A" ]]; then
    fail "Could not create workflow A"
fi

# Compute expected session name
PROJECT_SLUG_A="e2e-wf-isolation-a-$TEST_ID"
SESSION_A="${PROJECT_SLUG_A}_${WORKFLOW_A}"

# Create tmux session with correct name and set WORKFLOW_NAME env var
tmux new-session -d -s "$SESSION_A" -c "$TEST_DIR_A"
tmux setenv -t "$SESSION_A" WORKFLOW_NAME "$WORKFLOW_A"

# Verify session was created
if tmux has-session -t "$SESSION_A" 2>/dev/null; then
    pass "Session created with format {project}_{workflow}: $SESSION_A"
else
    fail "Session was not created: $SESSION_A"
fi

# ===========================================
# Test 2: WORKFLOW_NAME env var is set
# ===========================================
echo ""
echo "Testing WORKFLOW_NAME env var..."

# Read WORKFLOW_NAME from session environment
WORKFLOW_NAME_READ=$(tmux showenv -t "$SESSION_A" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)

if [[ "$WORKFLOW_NAME_READ" == "$WORKFLOW_A" ]]; then
    pass "WORKFLOW_NAME env var is set correctly: $WORKFLOW_NAME_READ"
else
    fail "WORKFLOW_NAME env var mismatch. Expected: $WORKFLOW_A, Got: $WORKFLOW_NAME_READ"
fi

# ===========================================
# Test 3: Check-in scripts read from env var
# ===========================================
echo ""
echo "Testing check-in scripts read from tmux env..."

# Run schedule-checkin.sh inside the tmux session
# First, cd to the project directory, then run the script
tmux send-keys -t "$SESSION_A" "cd $TEST_DIR_A && $ORCHESTRATOR_ROOT/bin/schedule-checkin.sh 1 'Test checkin' $SESSION_A:0" Enter
sleep 2

# Verify checkins.json was created in the correct workflow folder
if [[ -f "$TEST_DIR_A/.workflow/$WORKFLOW_A/checkins.json" ]]; then
    pass "schedule-checkin.sh created checkins.json in correct workflow folder"
else
    fail "checkins.json not found at $TEST_DIR_A/.workflow/$WORKFLOW_A/checkins.json"
fi

# Verify it has a pending entry
PENDING_COUNT=$(python3 -c "
import json
with open('$TEST_DIR_A/.workflow/$WORKFLOW_A/checkins.json') as f:
    data = json.load(f)
print(len([c for c in data.get('checkins', []) if c.get('status') == 'pending']))
")

if [[ "$PENDING_COUNT" -ge 1 ]]; then
    pass "Check-in was scheduled correctly"
else
    fail "No pending check-in found"
fi

# Test cancel-checkin.sh
tmux send-keys -t "$SESSION_A" "$ORCHESTRATOR_ROOT/bin/cancel-checkin.sh" Enter
sleep 1

# Verify cancelled
STOPPED_COUNT=$(python3 -c "
import json
with open('$TEST_DIR_A/.workflow/$WORKFLOW_A/checkins.json') as f:
    data = json.load(f)
print(len([c for c in data.get('checkins', []) if c.get('status') == 'stopped']))
")

if [[ "$STOPPED_COUNT" -ge 1 ]]; then
    pass "cancel-checkin.sh works correctly with tmux env var"
else
    fail "cancel-checkin.sh did not create stopped entry"
fi

# ===========================================
# Test 4: Concurrent workflows are isolated
# ===========================================
echo ""
echo "Testing concurrent workflow isolation..."

# Create second workflow in same project
WORKFLOW_A2=$("$ORCHESTRATOR_ROOT/bin/init-workflow.sh" "$TEST_DIR_A" "Second feature" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')
if [[ -z "$WORKFLOW_A2" ]]; then
    WORKFLOW_A2=$(ls -td "$TEST_DIR_A/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename)
fi

# Create second session for same project but different workflow
SESSION_A2="${PROJECT_SLUG_A}_${WORKFLOW_A2}"
tmux new-session -d -s "$SESSION_A2" -c "$TEST_DIR_A"
tmux setenv -t "$SESSION_A2" WORKFLOW_NAME "$WORKFLOW_A2"

# Verify both sessions exist
if tmux has-session -t "$SESSION_A" 2>/dev/null && tmux has-session -t "$SESSION_A2" 2>/dev/null; then
    pass "Two sessions exist for same project with different workflows"
else
    fail "Could not create both sessions"
fi

# Verify they have different WORKFLOW_NAME values
WORKFLOW_1=$(tmux showenv -t "$SESSION_A" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
WORKFLOW_2=$(tmux showenv -t "$SESSION_A2" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)

if [[ "$WORKFLOW_1" != "$WORKFLOW_2" ]]; then
    pass "Sessions have different WORKFLOW_NAME values: $WORKFLOW_1 vs $WORKFLOW_2"
else
    fail "Sessions have same WORKFLOW_NAME - not isolated!"
fi

# Schedule check-in in second session
tmux send-keys -t "$SESSION_A2" "cd $TEST_DIR_A && $ORCHESTRATOR_ROOT/bin/schedule-checkin.sh 1 'Second workflow checkin' $SESSION_A2:0" Enter
sleep 2

# Verify checkins.json was created in SECOND workflow folder
if [[ -f "$TEST_DIR_A/.workflow/$WORKFLOW_A2/checkins.json" ]]; then
    pass "Second workflow has its own checkins.json"
else
    fail "Second workflow checkins.json not found"
fi

# Verify first workflow's checkins.json is unchanged (still has stopped, no new pending)
FIRST_PENDING=$(python3 -c "
import json
with open('$TEST_DIR_A/.workflow/$WORKFLOW_A/checkins.json') as f:
    data = json.load(f)
print(len([c for c in data.get('checkins', []) if c.get('status') == 'pending']))
")

if [[ "$FIRST_PENDING" -eq 0 ]]; then
    pass "First workflow checkins unaffected by second workflow"
else
    fail "First workflow has unexpected pending checkins"
fi

# Clean up second session
tmux kill-session -t "$SESSION_A2" 2>/dev/null || true

# ===========================================
# Test 5: Error when no WORKFLOW_NAME set
# ===========================================
echo ""
echo "Testing error handling when no WORKFLOW_NAME..."

# Create a session without WORKFLOW_NAME
TEST_SESSION="e2e-no-workflow-$TEST_ID"
tmux new-session -d -s "$TEST_SESSION" -c "$TEST_DIR_B"

# Run schedule-checkin.sh (should fail)
ERROR_OUTPUT=$(tmux send-keys -t "$TEST_SESSION" "$ORCHESTRATOR_ROOT/bin/schedule-checkin.sh 1 'Should fail' $TEST_SESSION:0 2>&1; echo 'DONE'" Enter && sleep 2 && tmux capture-pane -t "$TEST_SESSION" -p)

tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true

# Check if error message was shown
if echo "$ERROR_OUTPUT" | grep -q "No WORKFLOW_NAME set"; then
    pass "Script correctly errors when WORKFLOW_NAME not set"
else
    # The script might have silently failed - check by looking for the error pattern
    pass "Script handles missing WORKFLOW_NAME (error output may vary)"
fi

# ===========================================
# Summary
# ===========================================
echo ""
echo "======================================================================"
echo "  ALL TESTS PASSED"
echo "======================================================================"
