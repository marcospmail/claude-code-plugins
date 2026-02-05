#!/bin/bash
# test-single-agent.sh
#
# E2E Test: Single Agent Creation
#
# Verifies creating just one agent works correctly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="single-agent"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-single-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Single Agent Creation                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup
mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"
tmux new-session -d -s "$SESSION_NAME" -n "pm-checkins" -c "$TEST_DIR"
tmux send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh $TEST_DIR 'Single agent test'" Enter
sleep 3

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "$WORKFLOW_NAME"
AGENTS_YML="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents.yml"

# Create single qa agent
tmux send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $PROJECT_ROOT/bin/create-team.sh $TEST_DIR qa" Enter
sleep 15

# Should have 2 windows (PM + 1 agent)
WINDOWS=$(tmux list-windows -t "$SESSION_NAME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WINDOWS" -eq 2 ]]; then
    pass "Created 2 windows (PM + 1 agent)"
else
    fail "Expected 2 windows, got $WINDOWS"
fi

# Should be named 'qa' not 'qa-1'
if grep -q "name: qa$" "$AGENTS_YML" 2>/dev/null; then
    pass "Single QA named 'qa' (no number suffix)"
else
    fail "Single QA should be named 'qa' not 'qa-1'"
fi

# QA window should be window 1
if tmux list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" | grep -q "1:qa"; then
    pass "QA agent in window 1"
else
    fail "QA should be in window 1"
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
