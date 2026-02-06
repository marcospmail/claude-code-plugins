#!/bin/bash
# test-send-message.sh
#
# E2E Test: send-message.sh Functionality
#
# Verifies messages are delivered to correct tmux targets

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="send-message"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-msg-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: send-message.sh Functionality                     ║"
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
}
trap cleanup EXIT

# Setup
mkdir -p "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -n "window0" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "window1" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "window2" -c "$TEST_DIR"

# Disable flow control in all windows so Ctrl+S (stash) doesn't freeze shells
# Note: In bash, Ctrl+S triggers forward-search-history, not Claude's stash
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "stty -ixon" Enter
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "stty -ixon" Enter
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "stty -ixon" Enter
sleep 2

echo "Testing send-message to different windows..."
echo ""

# Test 1: Send to window 0 (direct call - testing the script itself, not a Claude skill)
MSG1="TEST_MSG_WIN0_$(date +%s)"
"$PROJECT_ROOT/bin/send-message.sh" "$SESSION_NAME:0" "$MSG1"
sleep 2
OUTPUT0=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)
if echo "$OUTPUT0" | grep -q "$MSG1"; then
    pass "Message delivered to window 0"
else
    fail "Message not found in window 0"
fi

# Test 2: Send to window 1 (direct call - testing the script itself)
MSG2="TEST_MSG_WIN1_$(date +%s)"
"$PROJECT_ROOT/bin/send-message.sh" "$SESSION_NAME:1" "$MSG2"
sleep 2
OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)
if echo "$OUTPUT1" | grep -q "$MSG2"; then
    pass "Message delivered to window 1"
else
    fail "Message not found in window 1"
fi

# Test 3: Send to window 2 (direct call - testing the script itself)
MSG3="TEST_MSG_WIN2_$(date +%s)"
"$PROJECT_ROOT/bin/send-message.sh" "$SESSION_NAME:2" "$MSG3"
sleep 2
OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)
if echo "$OUTPUT2" | grep -q "$MSG3"; then
    pass "Message delivered to window 2"
else
    fail "Message not found in window 2"
fi

# Test 4: Verify messages don't cross-contaminate
if echo "$OUTPUT0" | grep -q "$MSG2"; then
    fail "Window 0 should not contain window 1's message"
else
    pass "Messages properly isolated (no cross-contamination)"
fi

# Test 5: Test with special characters (direct call - testing the script itself)
SPECIAL_MSG="Test with 'quotes' and \"double quotes\""
"$PROJECT_ROOT/bin/send-message.sh" "$SESSION_NAME:0" "$SPECIAL_MSG"
sleep 2
OUTPUT_SPECIAL=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)
if echo "$OUTPUT_SPECIAL" | grep -q "quotes"; then
    pass "Special characters handled correctly"
else
    fail "Special characters not handled properly"
fi

# Test 6: Verify the script contains Ctrl+S key sequence for stashing
# Note: Can't functionally test Ctrl+S in bash (triggers forward-search-history)
# but we can verify the script has the command
if grep -q "C-s" "$PROJECT_ROOT/bin/send-message.sh"; then
    pass "Script contains Ctrl+S stash command"
else
    fail "Script missing Ctrl+S stash command"
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
