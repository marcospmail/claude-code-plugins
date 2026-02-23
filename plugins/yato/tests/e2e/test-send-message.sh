#!/bin/bash
# test-send-message.sh
#
# E2E Test: send-message.sh Functionality
#
# Verifies that send-message.sh delivers messages to correct tmux targets:
# 1. Messages arrive at the specified window
# 2. Messages with special characters are handled correctly
# 3. Messages don't cross-contaminate between windows

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="send-message"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
BIN_DIR="$PROJECT_ROOT/bin"
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

# Wait for all shells to fully initialize (zsh plugins, cloud credentials, git status)
sleep 5

if tmux -L "$TMUX_SOCKET" has-session -t "$MSG_SESSION" 2>/dev/null; then
    pass "Target session created with 3 windows"
else
    fail "Failed to create target session"
    exit 1
fi

echo ""

# ============================================================
# PHASE 2: Send message to window 0 via send-message.sh
# ============================================================
echo "Phase 2: Testing send_message to window 0..."

MSG1="TEST_MSG_WIN0_$$"

TMUX_SOCKET="$TMUX_SOCKET" "$BIN_DIR/send-message.sh" "$MSG_SESSION:0" "$MSG1" 2>/dev/null
sleep 2

OUTPUT0=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:0" -p -S -50 2>/dev/null)
if echo "$OUTPUT0" | grep -q "$MSG1"; then
    pass "Message delivered to window 0"
else
    fail "Message not found in window 0"
fi

# ============================================================
# PHASE 3: Send message to window 1 via send-message.sh
# ============================================================
echo ""
echo "Phase 3: Testing send_message to window 1..."

MSG2="TEST_MSG_WIN1_$$"

TMUX_SOCKET="$TMUX_SOCKET" "$BIN_DIR/send-message.sh" "$MSG_SESSION:1" "$MSG2" 2>/dev/null
sleep 2

OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:1" -p -S -50 2>/dev/null)
if echo "$OUTPUT1" | grep -q "$MSG2"; then
    pass "Message delivered to window 1"
else
    fail "Message not found in window 1"
fi

# ============================================================
# PHASE 4: Send message to window 2 via send-message.sh
# ============================================================
echo ""
echo "Phase 4: Testing send_message to window 2..."

MSG3="TEST_MSG_WIN2_$$"

TMUX_SOCKET="$TMUX_SOCKET" "$BIN_DIR/send-message.sh" "$MSG_SESSION:2" "$MSG3" 2>/dev/null
sleep 2

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:2" -p -S -50 2>/dev/null)
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

OUTPUT0=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:0" -p -S -50 2>/dev/null)
if echo "$OUTPUT0" | grep -q "$MSG2"; then
    fail "Window 0 should not contain window 1's message"
else
    pass "Window 0 isolated from window 1"
fi

if echo "$OUTPUT0" | grep -q "$MSG3"; then
    fail "Window 0 should not contain window 2's message"
else
    pass "Window 0 isolated from window 2"
fi

OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:1" -p -S -50 2>/dev/null)
if echo "$OUTPUT1" | grep -q "$MSG1"; then
    fail "Window 1 should not contain window 0's message"
else
    pass "Window 1 isolated from window 0"
fi

# ============================================================
# PHASE 6: Test with special characters
# ============================================================
echo ""
echo "Phase 6: Testing special characters..."

SPECIAL_MSG="Test: special chars & <brackets> (parens) | pipe - run $TEST_NAME-$$"

TMUX_SOCKET="$TMUX_SOCKET" "$BIN_DIR/send-message.sh" "$MSG_SESSION:0" "$SPECIAL_MSG" 2>/dev/null
sleep 2

OUTPUT_SPECIAL=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$MSG_SESSION:0" -p -S -50 2>/dev/null)
if echo "$OUTPUT_SPECIAL" | grep -q "chars &"; then
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
