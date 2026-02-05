#!/bin/bash
# test-pm-discovery-questions.sh
#
# E2E Test: Verify PM briefing instructs proper discovery question behavior
#
# This test verifies that the PM briefing contains instructions for:
# 1. Asking "What are we building?" for new/empty projects
# 2. Asking "What would you like to accomplish?" for existing projects
# 3. Being conversational - ONE question at a time
# 4. Confirming understanding before proceeding
# 5. Summarizing and asking for confirmation

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-discovery-questions"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: PM Discovery Questions Behavior                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Project root: $PROJECT_ROOT"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup test environment
mkdir -p "$TEST_DIR"
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

# Read the PM briefing from orchestrator.py
# The briefing is in the start_pm_with_planning_briefing method - read entire method
ORCHESTRATOR_FILE="$PROJECT_ROOT/lib/orchestrator.py"

echo "Testing PM briefing content in orchestrator.py..."
echo ""

# Test 1: PM asks "What are we building?" for new/empty projects
echo "Test 1: New project discovery question..."
if grep -qi "What are we building" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes 'What are we building?' question for new projects"
else
    fail "PM briefing missing 'What are we building?' for new projects"
fi

# Test 2: PM asks "What would you like to accomplish?" for existing projects
echo "Test 2: Existing project discovery question..."
if grep -qi "What would you like to accomplish" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes 'What would you like to accomplish?' for existing projects"
else
    fail "PM briefing missing 'What would you like to accomplish?' for existing projects"
fi

# Test 3: PM should be conversational - ONE question at a time
echo "Test 3: One question at a time instruction..."
if grep -qi "ONE question at a time\|Ask ONE question" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing instructs asking ONE question at a time"
else
    fail "PM briefing missing 'ONE question at a time' instruction"
fi

# Test 4: PM should confirm understanding before proceeding
echo "Test 4: Confirmation before proceeding..."
if grep -qi "Is this correct\|clarification" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes confirmation step before proceeding"
else
    fail "PM briefing missing confirmation instruction"
fi

# Test 5: PM should summarize understanding
echo "Test 5: Summarize understanding instruction..."
if grep -qi "SUMMARIZE" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes instruction to SUMMARIZE understanding"
else
    fail "PM briefing missing SUMMARIZE instruction"
fi

# Test 6: PM should wait for user confirmation
echo "Test 6: Wait for user confirmation instruction..."
if grep -qi "Wait for confirmation\|wait for user" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes instruction to wait for user confirmation"
else
    fail "PM briefing missing 'wait for confirmation' instruction"
fi

# Test 7: PM should NOT skip questions or assume answers
echo "Test 7: Don't skip/assume instruction..."
if grep -qi "NEVER skip\|never assume" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes instruction to never skip questions/assume answers"
else
    fail "PM briefing missing 'never skip/assume' instruction"
fi

# Test 8: PM should handle PRD input options
echo "Test 8: PRD input options..."
if grep -qi "a brief description.*URL.*PRD" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing mentions PRD/description/URL input options"
else
    fail "PM briefing missing PRD input options"
fi

# Results
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)                                  ║"
    EXIT_CODE=0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                   ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
