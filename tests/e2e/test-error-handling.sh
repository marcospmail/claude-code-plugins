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
SESSION_NAME="e2e-error-$$"
export TMUX_SOCKET="yato-e2e-test"

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
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -f /tmp/e2e-*-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

mkdir -p "$TEST_DIR"

# Create tmux session for tests
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

echo "Testing error conditions..."
echo ""

# Test 1: notify-pm.sh without arguments shows usage
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/notify-pm.sh > /tmp/e2e-notify-$$.txt 2>&1; echo DONE" Enter
sleep 3
NOTIFY_OUTPUT=$(cat /tmp/e2e-notify-$$.txt 2>/dev/null)
if echo "$NOTIFY_OUTPUT" | grep -qi "usage"; then
    pass "notify-pm.sh shows usage when missing arguments"
else
    fail "notify-pm.sh should show usage when missing arguments"
fi

# Test 2: send-message.sh with missing arguments
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/send-message.sh > /tmp/e2e-send-$$.txt 2>&1; echo DONE" Enter
sleep 3
SEND_OUTPUT=$(cat /tmp/e2e-send-$$.txt 2>/dev/null)
if echo "$SEND_OUTPUT" | grep -qi "usage"; then
    pass "send-message.sh shows usage when missing arguments"
else
    fail "send-message.sh should show usage when missing arguments"
fi

# Test 3: create-team.sh with no agents specified
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Error test'" Enter
sleep 3

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "cd '$TEST_DIR' && TMUX='' $PROJECT_ROOT/bin/create-team.sh '$TEST_DIR' > /tmp/e2e-create-$$.txt 2>&1; echo DONE" Enter
sleep 3
CREATE_OUTPUT=$(cat /tmp/e2e-create-$$.txt 2>/dev/null)
if echo "$CREATE_OUTPUT" | grep -qi "no agent\|error\|usage"; then
    pass "create-team.sh errors when no agents specified"
else
    fail "create-team.sh should error when no agents specified"
fi

# Test 4: init-workflow.sh creates directories if missing
NEW_DIR="$TEST_DIR/new-project"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$NEW_DIR' 'New project test'" Enter
sleep 3
if [[ -d "$NEW_DIR/.workflow" ]]; then
    pass "init-workflow.sh creates directories as needed"
else
    fail "init-workflow.sh should create directories"
fi

# Test 5: Workflow utils functions handle missing files gracefully
# Clear WORKFLOW_NAME from tmux env so the function falls through to filesystem check
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" -u WORKFLOW_NAME 2>/dev/null || true
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "unset TMUX && source $PROJECT_ROOT/bin/workflow-utils.sh && get_current_workflow /nonexistent/path > /tmp/e2e-wfutils-$$.txt 2>&1; echo DONE" Enter
sleep 3
MISSING_WF=$(cat /tmp/e2e-wfutils-$$.txt 2>/dev/null | grep -v "DONE" || echo "")
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
