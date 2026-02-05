#!/bin/bash
# test-qa-test-file-permissions.sh
#
# E2E Test: QA Agent Test File Permissions
#
# BUG 8 REGRESSION TEST
#
# This test verifies:
# 1. QA agent identity.yml has can_modify_code: test-only
# 2. QA instructions explicitly state they CAN modify test files
# 3. QA instructions list test file directories (e2e/, tests/, __tests__/)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="qa-test-permissions"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-qa-perms-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: QA Test File Permissions (BUG 8)                  ║"
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
# PHASE 1: Setup and create QA agent
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

tmux new-session -d -s "$SESSION_NAME" -n "pm" -c "$TEST_DIR"

tmux send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test QA permissions'" Enter
sleep 3

WORKFLOW_NAME=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1 | xargs basename)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

tmux send-keys -t "$SESSION_NAME" "source $PROJECT_ROOT/bin/workflow-utils.sh && save_team_structure '$TEST_DIR' qa:qa:sonnet" Enter
sleep 3

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 2: Verify identity.yml can_modify_code value
# ============================================================
echo "Phase 2: Checking QA identity.yml..."

QA_IDENTITY="$WORKFLOW_PATH/agents/qa/identity.yml"

# Test 1: identity.yml exists
if [[ -f "$QA_IDENTITY" ]]; then
    pass "QA identity.yml exists"
else
    fail "QA identity.yml not found"
    exit 1
fi

# Test 2: can_modify_code is "test-only" (not false)
if grep -q "^can_modify_code: test-only$" "$QA_IDENTITY" 2>/dev/null; then
    pass "QA identity.yml has can_modify_code: test-only"
else
    CAN_MODIFY=$(grep "can_modify_code:" "$QA_IDENTITY" 2>/dev/null)
    fail "QA identity.yml has wrong can_modify_code: $CAN_MODIFY"
fi

echo ""

# ============================================================
# PHASE 3: Verify QA instructions clarify test file permissions
# ============================================================
echo "Phase 3: Checking QA instructions..."

QA_INSTRUCTIONS="$WORKFLOW_PATH/agents/qa/instructions.md"

# Test 3: Instructions exist
if [[ -f "$QA_INSTRUCTIONS" ]]; then
    pass "QA instructions.md exists"
else
    fail "QA instructions.md not found"
    exit 1
fi

# Test 4: Instructions mention test files CAN be modified
if grep -qi "can.*modify.*test\|can.*write.*test\|allowed.*test" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA instructions say test files CAN be modified"
else
    fail "QA instructions don't clarify test file permissions"
fi

# Test 5: Instructions mention e2e/ directory
if grep -q "e2e/" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA instructions mention e2e/ directory"
else
    fail "QA instructions don't mention e2e/ directory"
fi

# Test 6: Instructions mention tests/ directory
if grep -q "tests/" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA instructions mention tests/ directory"
else
    fail "QA instructions don't mention tests/ directory"
fi

# Test 7: Instructions mention what directories are OFF-LIMITS
if grep -qi "src/\|lib/\|production\|cannot.*modify" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA instructions mention production code restrictions"
else
    fail "QA instructions don't clarify production code restrictions"
fi

# Test 8: Description mentions test files
if grep -qi "CAN write.*test\|CAN.*modify.*TEST" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA role description mentions test file permissions"
else
    fail "QA role description doesn't mention test file permissions"
fi

echo ""

# ============================================================
# PHASE 4: Verify init-agent-files.sh template
# ============================================================
echo "Phase 4: Checking init-agent-files.sh template..."

INIT_SCRIPT="$PROJECT_ROOT/bin/init-agent-files.sh"

# Test 9: QA role sets can_modify_code to test-only
# The script has: qa) CAN_MODIFY_CODE="test-only"
if grep -A 2 "qa)" "$INIT_SCRIPT" 2>/dev/null | grep -q "test-only"; then
    pass "init-agent-files.sh sets QA can_modify_code to test-only"
else
    fail "init-agent-files.sh doesn't set QA can_modify_code correctly"
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
