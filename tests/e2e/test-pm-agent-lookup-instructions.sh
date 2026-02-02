#!/bin/bash
# test-pm-agent-lookup-instructions.sh
#
# E2E Test: PM Instructions Contain Agent Lookup Guidance
#
# BUG 6 REGRESSION TEST
#
# This test verifies:
# 1. PM instructions contain grep example for looking up agent windows
# 2. Instructions specify to look up by NAME not ROLE
# 3. Instructions mention agents.yml

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-agent-lookup"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-pm-lookup-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: PM Agent Lookup Instructions (BUG 6)              ║"
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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup and create workflow
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

tmux new-session -d -s "$SESSION_NAME" -n "pm" -c "$TEST_DIR"

"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test PM lookup" > /dev/null 2>&1

WORKFLOW_NAME=$(cat "$TEST_DIR/.workflow/current")
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 2: Verify PM instructions contain lookup guidance
# ============================================================
echo "Phase 2: Checking PM instructions..."

PM_INSTRUCTIONS="$WORKFLOW_PATH/agents/pm/instructions.md"

# Test 1: PM instructions file exists
if [[ -f "$PM_INSTRUCTIONS" ]]; then
    pass "PM instructions.md exists"
else
    fail "PM instructions.md not found at $PM_INSTRUCTIONS"
    exit 1
fi

# Test 2: Instructions mention looking up by NAME
if grep -qi "name.*not.*role\|by.*name\|agent.*name" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "PM instructions mention looking up by AGENT NAME"
else
    fail "PM instructions don't emphasize lookup by NAME"
fi

# Test 3: Instructions contain grep example
if grep -q "grep.*name:" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "PM instructions contain grep example for agent lookup"
else
    fail "PM instructions missing grep example"
fi

# Test 4: Instructions mention agents.yml
if grep -q "agents.yml" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "PM instructions mention agents.yml"
else
    fail "PM instructions don't mention agents.yml"
fi

echo ""

# ============================================================
# PHASE 3: Verify init-workflow.sh template
# ============================================================
echo "Phase 3: Checking init-workflow.sh template..."

INIT_WORKFLOW="$PROJECT_ROOT/bin/init-workflow.sh"

# Test 5: init-workflow.sh contains agent lookup guidance
if grep -q 'grep.*"name:' "$INIT_WORKFLOW" 2>/dev/null; then
    pass "init-workflow.sh template contains grep example"
else
    fail "init-workflow.sh template missing grep example"
fi

# Test 6: Template mentions looking up by NAME
if grep -qi "by.*name\|AGENT.*NAME" "$INIT_WORKFLOW" 2>/dev/null; then
    pass "init-workflow.sh template emphasizes lookup by NAME"
else
    fail "init-workflow.sh template doesn't emphasize lookup by NAME"
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
