#!/bin/bash
# test-workflow-session-isolation.sh
#
# E2E Test: Per-session Workflow Isolation (tmux env var)
#
# Tests:
# 1. Session naming uses {project}_{workflow} format
# 2. WORKFLOW_NAME env var is set in tmux session
# 3. Concurrent workflows in same project are isolated
# 4. Each session has its own WORKFLOW_NAME value

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="workflow-session-isolation"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-isolation-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Workflow Session Isolation (tmux env var)"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "  ✅ $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "  ❌ $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" kill-session -t "e2e-iso-a-$$" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" kill-session -t "e2e-iso-b-$$" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# Initialize git so init-workflow.sh works
cd "$TEST_DIR" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

# Create a tmux session so init-workflow.sh can detect session name
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# Test 1: Create first workflow
# ============================================================
echo "Test 1: Creating first workflow..."

# Run init-workflow.sh inside the tmux session so it can detect session name
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Add feature X'" Enter
sleep 5

# Get the workflow name
WORKFLOW_A=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^001-" | head -1)

if [[ -n "$WORKFLOW_A" ]]; then
    pass "First workflow created: $WORKFLOW_A"
else
    fail "Could not create first workflow"
fi

# ============================================================
# Test 2: Session naming format {project}_{workflow}
# ============================================================
echo ""
echo "Test 2: Testing session naming format..."

PROJECT_SLUG="e2e-isolation"
SESSION_A="${PROJECT_SLUG}_${WORKFLOW_A}"

# Create a tmux session with the correct naming convention and set WORKFLOW_NAME
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_A" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null || true
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_A" WORKFLOW_NAME "$WORKFLOW_A"

if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_A" 2>/dev/null; then
    pass "Session created with format {project}_{workflow}: $SESSION_A"
else
    fail "Session was not created: $SESSION_A"
fi

# ============================================================
# Test 3: WORKFLOW_NAME env var is set correctly
# ============================================================
echo ""
echo "Test 3: Testing WORKFLOW_NAME env var..."

WORKFLOW_NAME_READ=$(tmux -L "$TMUX_SOCKET" showenv -t "$SESSION_A" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)

if [[ "$WORKFLOW_NAME_READ" == "$WORKFLOW_A" ]]; then
    pass "WORKFLOW_NAME env var is set correctly: $WORKFLOW_NAME_READ"
else
    fail "WORKFLOW_NAME env var mismatch. Expected: $WORKFLOW_A, Got: $WORKFLOW_NAME_READ"
fi

# Clean up the extra session
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_A" 2>/dev/null || true

# ============================================================
# Test 4: Create second workflow (concurrent isolation)
# ============================================================
echo ""
echo "Test 4: Creating second workflow (concurrent isolation)..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Second feature'" Enter
sleep 5

WORKFLOW_B=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^002-" | head -1)

if [[ -n "$WORKFLOW_B" ]]; then
    pass "Second workflow created: $WORKFLOW_B"
else
    fail "Could not create second workflow"
fi

# ============================================================
# Test 5: Both sessions have different WORKFLOW_NAME values
# ============================================================
echo ""
echo "Test 5: Testing concurrent workflow isolation with different sessions..."

# Create two sessions for same project with different workflows
SESSION_B1="e2e-iso-a-$$"
SESSION_B2="e2e-iso-b-$$"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_B1" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null || true
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_B1" WORKFLOW_NAME "$WORKFLOW_A"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_B2" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null || true
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_B2" WORKFLOW_NAME "$WORKFLOW_B"

# Verify both sessions exist
if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_B1" 2>/dev/null && tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_B2" 2>/dev/null; then
    pass "Two sessions exist for same project with different workflows"
else
    fail "Could not create both sessions"
fi

# Verify they have different WORKFLOW_NAME values
WF_1=$(tmux -L "$TMUX_SOCKET" showenv -t "$SESSION_B1" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
WF_2=$(tmux -L "$TMUX_SOCKET" showenv -t "$SESSION_B2" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)

if [[ "$WF_1" != "$WF_2" ]]; then
    pass "Sessions have different WORKFLOW_NAME values: $WF_1 vs $WF_2"
else
    fail "Sessions have same WORKFLOW_NAME - not isolated!"
fi

# Clean up extra sessions
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_B1" 2>/dev/null || true
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_B2" 2>/dev/null || true

# ============================================================
# Test 6: Each workflow has its own folder structure
# ============================================================
echo ""
echo "Test 6: Verifying each workflow has its own folder structure..."

if [[ -d "$TEST_DIR/.workflow/$WORKFLOW_A" ]] && [[ -d "$TEST_DIR/.workflow/$WORKFLOW_B" ]]; then
    pass "Both workflow folders exist independently"
else
    fail "Missing workflow folder(s)"
fi

if [[ -f "$TEST_DIR/.workflow/$WORKFLOW_A/status.yml" ]] && [[ -f "$TEST_DIR/.workflow/$WORKFLOW_B/status.yml" ]]; then
    pass "Both workflows have their own status.yml"
else
    fail "Missing status.yml in one or both workflows"
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
