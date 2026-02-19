#!/bin/bash
# test-agent-polling-guidance.sh
#
# E2E Test: Agent Instructions Contain Polling Guidance
#
# BUG 3 REGRESSION TEST
#
# This test verifies:
# 1. New agents get instructions containing "Waiting for Dependencies" section
# 2. Instructions mention max retry guidance
# 3. Instructions tell agents to notify PM when blocked
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All script execution goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-polling-guidance"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-polling-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Agent Polling Guidance (BUG 3)"
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
# PHASE 1: Setup and create agent through Claude
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm" -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

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
# PHASE 2: Initialize workflow through Claude
# ============================================================
echo "Phase 2: Initializing workflow through Claude..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test polling guidance'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

WORKFLOW_NAME=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1 | xargs basename)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Save team structure through Claude
# ============================================================
echo "Phase 3: Saving team structure through Claude..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: source $PROJECT_ROOT/bin/workflow-utils.sh && save_team_structure '$TEST_DIR' developer:developer:sonnet"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

echo "  - Team structure saved"
echo ""

# ============================================================
# PHASE 4: Verify polling guidance in generated instructions
# ============================================================
echo "Phase 4: Checking agent instructions for polling guidance..."

INSTRUCTIONS_FILE="$WORKFLOW_PATH/agents/developer/instructions.md"

# Test 1: Instructions file exists
if [[ -f "$INSTRUCTIONS_FILE" ]]; then
    pass "Agent instructions.md exists"
else
    fail "instructions.md not found at $INSTRUCTIONS_FILE"
    exit 1
fi

# Test 2: Contains "Waiting for Dependencies" section
if grep -q "Waiting for Dependencies" "$INSTRUCTIONS_FILE" 2>/dev/null; then
    pass "Instructions contain 'Waiting for Dependencies' section"
else
    fail "Instructions missing 'Waiting for Dependencies' section"
fi

# Test 3: Contains max retry guidance
if grep -q "Maximum.*retries\|5 retries\|retries.*5" "$INSTRUCTIONS_FILE" 2>/dev/null; then
    pass "Instructions mention max retries"
else
    fail "Instructions missing max retry guidance"
fi

# Test 4: Contains notify PM guidance for blocked state
if grep -q "notify.*PM.*BLOCKED\|BLOCKED.*notify" "$INSTRUCTIONS_FILE" 2>/dev/null; then
    pass "Instructions tell agents to notify PM when blocked"
else
    fail "Instructions missing PM notification for blocked state"
fi

# Test 5: Constraints contain polling prohibition
CONSTRAINTS_FILE="$WORKFLOW_PATH/agents/developer/constraints.md"
if grep -qi "polling\|infinite" "$CONSTRAINTS_FILE" 2>/dev/null; then
    pass "Constraints contain polling prohibition"
else
    fail "Constraints missing polling prohibition"
fi

# Test 6: Contains increasing delay guidance
if grep -q "30s\|60s\|increasing\|delay" "$INSTRUCTIONS_FILE" 2>/dev/null; then
    pass "Instructions mention increasing delays"
else
    fail "Instructions missing increasing delay guidance"
fi

echo ""

# ============================================================
# PHASE 5: Verify init-agent-files.sh template contains guidance
# ============================================================
echo "Phase 5: Checking init-agent-files.sh template..."

INIT_SCRIPT="$PROJECT_ROOT/bin/init-agent-files.sh"

# Test 7: init-agent-files.sh contains polling guidance
if grep -q "Waiting for Dependencies" "$INIT_SCRIPT" 2>/dev/null; then
    pass "init-agent-files.sh template contains polling guidance"
else
    fail "init-agent-files.sh template missing polling guidance"
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
