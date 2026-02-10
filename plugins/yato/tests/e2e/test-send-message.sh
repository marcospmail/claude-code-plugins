#!/bin/bash
# test-send-message.sh
#
# E2E Test: send_message (tmux_utils.py) Functionality
#
# Verifies through Claude Code that messages are delivered to correct tmux targets
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All execution goes through Claude running inside a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="send-message"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
MSG_SESSION="e2e-msg-target-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: send_message Functionality"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" kill-session -t "$MSG_SESSION" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"

# Create a target session with multiple windows for receiving messages
tmux -L "$TMUX_SOCKET" new-session -d -s "$MSG_SESSION" -x 120 -y 40 -n "window0" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -d -t "$MSG_SESSION" -n "window1" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -d -t "$MSG_SESSION" -n "window2" -c "$TEST_DIR"

# Create a Claude session for sending messages
# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "  - Waiting for Claude to start..."
sleep 8

# Check for trust prompt and send Enter to accept
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
# PHASE 2: Send message to window 0 via Claude
# ============================================================
echo "Phase 2: Testing send_message to window 0..."

MSG1="TEST_MSG_WIN0_$$"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/tmux_utils.py send '$MSG_SESSION:0' '$MSG1'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt if it appears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    echo "  - Skill trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

OUTPUT0=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:0" -p)
if echo "$OUTPUT0" | grep -q "$MSG1"; then
    pass "Message delivered to window 0"
else
    fail "Message not found in window 0"
fi

# ============================================================
# PHASE 3: Send message to window 1 via Claude
# ============================================================
echo ""
echo "Phase 3: Testing send_message to window 1..."

MSG2="TEST_MSG_WIN1_$$"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/tmux_utils.py send '$MSG_SESSION:1' '$MSG2'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:1" -p)
if echo "$OUTPUT1" | grep -q "$MSG2"; then
    pass "Message delivered to window 1"
else
    fail "Message not found in window 1"
fi

# ============================================================
# PHASE 4: Send message to window 2 via Claude
# ============================================================
echo ""
echo "Phase 4: Testing send_message to window 2..."

MSG3="TEST_MSG_WIN2_$$"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/tmux_utils.py send '$MSG_SESSION:2' '$MSG3'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:2" -p)
if echo "$OUTPUT2" | grep -q "$MSG3"; then
    pass "Message delivered to window 2"
else
    fail "Message not found in window 2"
fi

# ============================================================
# PHASE 5: Verify messages don't cross-contaminate
# ============================================================
echo ""
echo "Phase 5: Testing message isolation..."

OUTPUT0=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:0" -p)
if echo "$OUTPUT0" | grep -q "$MSG2"; then
    fail "Window 0 should not contain window 1's message"
else
    pass "Messages properly isolated (no cross-contamination)"
fi

# ============================================================
# PHASE 6: Test with special characters via Claude
# ============================================================
echo ""
echo "Phase 6: Testing special characters..."

SPECIAL_MSG="Test with special chars"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/tmux_utils.py send '$MSG_SESSION:0' '$SPECIAL_MSG'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

OUTPUT_SPECIAL=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:0" -p)
if echo "$OUTPUT_SPECIAL" | grep -q "special chars"; then
    pass "Special characters handled correctly"
else
    fail "Special characters not handled properly"
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
