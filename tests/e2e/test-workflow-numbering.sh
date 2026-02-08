#!/bin/bash
# test-workflow-numbering.sh
#
# E2E Test: Workflow Sequential Numbering
#
# Verifies that workflow directories are created with sequential numbering (001, 002, 003)
# Tests creating multiple workflows and validates correct numbering sequence.
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All workflow creation goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="workflow-numbering"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-numbering-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Workflow Sequential Numbering"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
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
cd "$TEST_DIR" && git init -q && git config user.name Test && git config user.email test@test.com

echo "  - Test directory: $TEST_DIR"
echo "  - Session: $SESSION_NAME"

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
# Test 1: Create first workflow through Claude
# ============================================================
echo "Test 1: Creating first workflow..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'First workflow'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Debug: show what Claude did
echo "  Debug - After first workflow:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -30 | tail -15
echo ""

# Verify first workflow directory
WF1=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^001-" | head -1)
if [[ "$WF1" == 001-* ]]; then
    pass "First workflow created with 001- prefix: $WF1"
else
    fail "First workflow should start with 001-, got: $WF1"
fi

# Verify status.yml exists
if [[ -f "$TEST_DIR/.workflow/$WF1/status.yml" ]]; then
    pass "status.yml created in first workflow"
else
    fail "status.yml not found in first workflow"
fi

# ============================================================
# Test 2: Create second workflow through Claude
# ============================================================
echo ""
echo "Test 2: Creating second workflow..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Second workflow'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Debug: show what Claude did
echo "  Debug - After second workflow:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -30 | tail -15
echo ""

# Verify second workflow directory
WF2=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^002-" | head -1)
if [[ "$WF2" == 002-* ]]; then
    pass "Second workflow created with 002- prefix: $WF2"
else
    fail "Second workflow should start with 002-, got: $WF2"
fi

# Verify first workflow still exists
if [[ -d "$TEST_DIR/.workflow/$WF1" ]]; then
    pass "First workflow still exists after creating second"
else
    fail "First workflow was removed (should persist)"
fi

# ============================================================
# Test 3: Create third workflow through Claude
# ============================================================
echo ""
echo "Test 3: Creating third workflow..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Third workflow'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Debug: show what Claude did
echo "  Debug - After third workflow:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -30 | tail -15
echo ""

# Verify third workflow directory
WF3=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^003-" | head -1)
if [[ "$WF3" == 003-* ]]; then
    pass "Third workflow created with 003- prefix: $WF3"
else
    fail "Third workflow should start with 003-, got: $WF3"
fi

# ============================================================
# Test 4: Verify workflow count
# ============================================================
echo ""
echo "Test 4: Verifying total workflow count..."

WORKFLOW_COUNT=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WORKFLOW_COUNT" -eq 3 ]]; then
    pass "Exactly 3 workflow directories created"
else
    fail "Expected 3 workflow directories, found $WORKFLOW_COUNT"
fi

# ============================================================
# Test 5: Verify sequential numbering integrity
# ============================================================
echo ""
echo "Test 5: Verifying sequential numbering (001, 002, 003)..."

if [[ -n "$WF1" ]] && [[ -n "$WF2" ]] && [[ -n "$WF3" ]]; then
    pass "All three workflows have sequential numbers"
else
    fail "Workflow numbering sequence is incomplete"
fi

# ============================================================
# Test 6: Verify latest workflow is 003
# ============================================================
echo ""
echo "Test 6: Verifying latest workflow is 003-*..."

LATEST=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | sort | tail -1)
if [[ "$LATEST" == "$WF3" ]]; then
    pass "Latest workflow is 003-* (correct sequential order)"
else
    fail "Latest workflow should be $WF3, got: $LATEST"
fi

# ============================================================
# Test 7: Verify 'current' does NOT exist
# ============================================================
echo ""
echo "Test 7: Verifying 'current' file does NOT exist..."

if [[ ! -L "$TEST_DIR/.workflow/current" ]] && [[ ! -f "$TEST_DIR/.workflow/current" ]]; then
    pass "'current' file does not exist (correct - multiple workflows can run)"
else
    fail "'current' file/symlink exists but should not"
fi

# Display final directory structure
echo ""
echo "Final workflow directory structure:"
ls -la "$TEST_DIR/.workflow/" 2>/dev/null || echo "  .workflow directory not found"

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    exit 0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    exit 1
fi
