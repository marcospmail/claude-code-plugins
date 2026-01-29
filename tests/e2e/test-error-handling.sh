#!/bin/bash
# test-error-handling.sh
#
# E2E Test: Error Handling
#
# Verifies proper error messages for various error conditions

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="error-handling"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Error Handling                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$TEST_DIR"

echo "Testing error conditions..."
echo ""

# Test 1: notify-pm.sh without arguments shows usage
NOTIFY_OUTPUT=$("$PROJECT_ROOT/bin/notify-pm.sh" 2>&1 || true)
if echo "$NOTIFY_OUTPUT" | grep -qi "usage"; then
    pass "notify-pm.sh shows usage when missing arguments"
else
    fail "notify-pm.sh should show usage when missing arguments"
fi

# Test 2: send-message.sh with missing arguments
SEND_OUTPUT=$("$PROJECT_ROOT/bin/send-message.sh" 2>&1 || true)
if echo "$SEND_OUTPUT" | grep -qi "usage"; then
    pass "send-message.sh shows usage when missing arguments"
else
    fail "send-message.sh should show usage when missing arguments"
fi

# Test 3: create-team.sh with no agents specified
SESSION_NAME="e2e-error-$$"
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Error test" > /dev/null 2>&1

CREATE_OUTPUT=$(cd "$TEST_DIR" && TMUX="" "$PROJECT_ROOT/bin/create-team.sh" "$TEST_DIR" 2>&1 || true)
if echo "$CREATE_OUTPUT" | grep -qi "no agent\|error\|usage"; then
    pass "create-team.sh errors when no agents specified"
else
    fail "create-team.sh should error when no agents specified"
fi

tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true

# Test 4: init-workflow.sh creates directories if missing
NEW_DIR="$TEST_DIR/new-project"
"$PROJECT_ROOT/bin/init-workflow.sh" "$NEW_DIR" "New project test" > /dev/null 2>&1
if [[ -d "$NEW_DIR/.workflow" ]]; then
    pass "init-workflow.sh creates directories as needed"
else
    fail "init-workflow.sh should create directories"
fi

# Test 5: Workflow utils functions handle missing files gracefully
source "$PROJECT_ROOT/bin/workflow-utils.sh"
MISSING_WF=$(get_current_workflow "/nonexistent/path" 2>/dev/null || echo "")
if [[ -z "$MISSING_WF" ]]; then
    pass "get_current_workflow returns empty for missing path"
else
    fail "get_current_workflow should return empty for missing path"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                  ║"
    exit 0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                        ║"
    exit 1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
