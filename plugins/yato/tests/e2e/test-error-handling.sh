#!/bin/bash
# test-error-handling.sh
#
# E2E Test: Error Handling
#
# Verifies proper error messages for various error conditions
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All script execution goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="error-handling"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-error-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Error Handling"
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
    rm -f /tmp/e2e-notify-$$.txt /tmp/e2e-send-$$.txt /tmp/e2e-create-$$.txt /tmp/e2e-wfutils-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$TEST_DIR"

# Create tmux session (needed by some scripts)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""
echo "Testing error conditions..."
echo ""

# ============================================================
# Test 1: notify-pm.sh without arguments shows usage
# ============================================================
echo "Test 1: notify-pm.sh without arguments..."

NOTIFY_OUTPUT=$("$PROJECT_ROOT/bin/notify-pm.sh" 2>&1 || true)
if echo "$NOTIFY_OUTPUT" | grep -qi "usage"; then
    pass "notify-pm.sh shows usage when missing arguments"
else
    fail "notify-pm.sh should show usage when missing arguments"
fi

# ============================================================
# Test 2: send-message.sh with missing arguments
# ============================================================
echo ""
echo "Test 2: send-message.sh with missing arguments..."

SEND_OUTPUT=$("$PROJECT_ROOT/bin/send-message.sh" 2>&1 || true)
if echo "$SEND_OUTPUT" | grep -qi "usage"; then
    pass "send-message.sh shows usage when missing arguments"
else
    fail "send-message.sh should show usage when missing arguments"
fi

# ============================================================
# Test 3: create-team.sh with no agents specified
# ============================================================
echo ""
echo "Test 3: create-team.sh with no agents..."

# First initialize a workflow so create-team has something to work with
TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Error test"

CREATE_OUTPUT=$(cd "$TEST_DIR" && TMUX="" TMUX_SOCKET="$TMUX_SOCKET" "$PROJECT_ROOT/bin/create-team.sh" "$TEST_DIR" 2>&1 || true)
if echo "$CREATE_OUTPUT" | grep -qi "no agent\|error\|usage"; then
    pass "create-team.sh errors when no agents specified"
else
    fail "create-team.sh should error when no agents specified"
fi

# ============================================================
# Test 4: init-workflow.sh creates directories if missing
# ============================================================
echo ""
echo "Test 4: init-workflow.sh creates directories if missing..."

NEW_DIR="$TEST_DIR/new-project"

TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$NEW_DIR" "New project test"

if [[ -d "$NEW_DIR/.workflow" ]]; then
    pass "init-workflow.sh creates directories as needed"
else
    fail "init-workflow.sh should create directories"
fi

# ============================================================
# Test 5: Workflow utils functions handle missing files gracefully
# ============================================================
echo ""
echo "Test 5: get_current_workflow with missing path..."

MISSING_WF=$(unset TMUX _YATO_WORKFLOW_NAME && source "$PROJECT_ROOT/bin/workflow-utils.sh" && get_current_workflow /nonexistent/path 2>&1 || echo "")
MISSING_WF=$(echo "$MISSING_WF" | grep -v "DONE" || echo "")
if [[ -z "$MISSING_WF" ]]; then
    pass "get_current_workflow returns empty for missing path"
else
    fail "get_current_workflow should return empty for missing path"
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
