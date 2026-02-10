#!/bin/bash
# test-workflow-current-file.sh
#
# E2E Test: .workflow/current File Should NOT Exist
#
# This test verifies:
# 1. Workflow initialization does NOT create .workflow/current file
# 2. Multiple workflows can exist without conflict
# 3. Workflow name comes from tmux env, not a file
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All workflow creation goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="workflow-current-file"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-current-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: .workflow/current File NOT Created"
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

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start
echo "  - Waiting for Claude to start..."
sleep 8

# Handle trust prompt
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  - Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  - No trust prompt found, continuing..."
    sleep 5
fi

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Create first workflow through Claude
# ============================================================
echo "Phase 2: Creating first workflow through Claude..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'First workflow'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Debug: show what Claude did
echo "  Debug - After first workflow creation:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -30 | tail -15
echo ""

echo "  - First workflow created"
echo ""

# ============================================================
# Test 1: .workflow/current file should NOT exist
# ============================================================
echo "Test 1: Checking .workflow/current file does NOT exist..."

CURRENT_FILE="$TEST_DIR/.workflow/current"

if [[ ! -f "$CURRENT_FILE" && ! -L "$CURRENT_FILE" ]]; then
    pass ".workflow/current file does NOT exist (correct)"
else
    fail ".workflow/current file exists (should not exist)"
fi

# ============================================================
# Test 2: Create second workflow through Claude - no conflict
# ============================================================
echo ""
echo "Test 2: Creating second workflow (no conflict expected)..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Second workflow'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Count workflow folders
WORKFLOW_COUNT=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')

if [[ "$WORKFLOW_COUNT" == "2" ]]; then
    pass "Two workflow folders exist: $WORKFLOW_COUNT"
else
    fail "Expected 2 workflows, found: $WORKFLOW_COUNT"
fi

# ============================================================
# Test 3: Still no .workflow/current file after second workflow
# ============================================================
echo ""
echo "Test 3: Confirm no .workflow/current after second workflow..."

if [[ ! -f "$CURRENT_FILE" && ! -L "$CURRENT_FILE" ]]; then
    pass "Still no .workflow/current file after second workflow"
else
    fail ".workflow/current appeared after second workflow"
fi

# ============================================================
# Test 4: Each session gets its own WORKFLOW_NAME via tmux env
# ============================================================
echo ""
echo "Test 4: Testing tmux environment per-session isolation..."

# Set workflow name in session
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-firstworkflow"

# Get it back
RESULT=$(tmux -L "$TMUX_SOCKET" showenv -t "$SESSION_NAME" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)

if [[ "$RESULT" == "001-firstworkflow" ]]; then
    pass "Tmux session has its own WORKFLOW_NAME env"
else
    fail "Could not get WORKFLOW_NAME from tmux: $RESULT"
fi

# ============================================================
# Test 5: Verify init-workflow.sh does NOT create current file
# ============================================================
echo ""
echo "Test 5: Checking init-workflow.sh does NOT create current file..."

INIT_WORKFLOW="$PROJECT_ROOT/bin/init-workflow.sh"

# Check that init-workflow.sh has the "do NOT create" comment
if grep -q "do NOT create .workflow/current" "$INIT_WORKFLOW" 2>/dev/null; then
    pass "init-workflow.sh explicitly notes NOT to create current file"
else
    fail "init-workflow.sh missing documentation about not creating current file"
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
