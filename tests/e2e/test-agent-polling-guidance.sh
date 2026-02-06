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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-polling-guidance"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-polling-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Polling Guidance (BUG 3)                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo ""

# Track test results
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

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup and create agent
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -n "pm" -c "$TEST_DIR"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test polling guidance'" Enter
sleep 3

WORKFLOW_NAME=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1 | xargs basename)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "source $PROJECT_ROOT/bin/workflow-utils.sh && save_team_structure '$TEST_DIR' developer:developer:sonnet" Enter
sleep 3

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 2: Verify polling guidance in generated instructions
# ============================================================
echo "Phase 2: Checking agent instructions for polling guidance..."

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

# Test 5: Contains example of bad polling (infinite loop)
if grep -q "while true\|infinite" "$INSTRUCTIONS_FILE" 2>/dev/null; then
    pass "Instructions show bad polling example to avoid"
else
    fail "Instructions missing bad polling example"
fi

# Test 6: Contains increasing delay guidance
if grep -q "30s\|60s\|increasing\|delay" "$INSTRUCTIONS_FILE" 2>/dev/null; then
    pass "Instructions mention increasing delays"
else
    fail "Instructions missing increasing delay guidance"
fi

echo ""

# ============================================================
# PHASE 3: Verify init-agent-files.sh template contains guidance
# ============================================================
echo "Phase 3: Checking init-agent-files.sh template..."

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
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                ║"
    EXIT_CODE=0
else
    printf "║  ❌ SOME TESTS FAILED (%d failed, %d passed)                      ║\n" $TESTS_FAILED $TESTS_PASSED
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
