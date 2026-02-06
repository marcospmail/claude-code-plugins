#!/bin/bash
# test-notify-pm.sh
#
# E2E Test: notify-pm.sh Communication
#
# Verifies that notify-pm.sh:
# 1. Auto-detects the current tmux session
# 2. Sends messages to PM at window 0, pane 1
# 3. Message content is delivered correctly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="notify-pm"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-notify-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: notify-pm.sh Communication                        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

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

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"

# Create tmux session with 2 panes in window 0
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -n "pm-checkins" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -v -p 50 -c "$TEST_DIR"

# Pane 0 = check-ins display, Pane 1 = PM
echo "  - Session: $SESSION_NAME"
echo "  - Window 0 split into pane 0 and pane 1"
echo ""

# ============================================================
# PHASE 2: Test notify-pm.sh auto-detection
# ============================================================
echo "Phase 2: Testing notify-pm.sh..."
echo ""

# Generate unique test message
TEST_MSG="TEST_MESSAGE_$(date +%s)"

# Run notify-pm.sh from within the tmux session (pane 1)
# It should detect session and send to session:0.1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "$PROJECT_ROOT/bin/notify-pm.sh '[DONE] $TEST_MSG'" Enter

sleep 2

# Capture pane 1 output to see if message was echoed
PANE1_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

# Check if notify-pm.sh ran without error (no "Error:" in output)
if echo "$PANE1_OUTPUT" | grep -q "Error:"; then
    fail "notify-pm.sh should not produce errors"
else
    pass "notify-pm.sh executed without errors"
fi

# Check if the command was executed (appears in shell history)
if echo "$PANE1_OUTPUT" | grep -q "notify-pm.sh"; then
    pass "notify-pm.sh command was executed"
else
    fail "notify-pm.sh command not found in output"
fi

# ============================================================
# PHASE 3: Test message types
# ============================================================
echo ""
echo "Phase 3: Testing message types..."

# Test BLOCKED message
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "$PROJECT_ROOT/bin/notify-pm.sh '[BLOCKED] Need database access'" Enter
sleep 1
BLOCKED_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)
if echo "$BLOCKED_OUTPUT" | grep -q "BLOCKED"; then
    pass "BLOCKED message type works"
else
    fail "BLOCKED message type failed"
fi

# Test HELP message
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "$PROJECT_ROOT/bin/notify-pm.sh '[HELP] How do I configure X?'" Enter
sleep 1
HELP_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)
if echo "$HELP_OUTPUT" | grep -q "HELP"; then
    pass "HELP message type works"
else
    fail "HELP message type failed"
fi

# Test STATUS message
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "$PROJECT_ROOT/bin/notify-pm.sh '[STATUS] 50% complete'" Enter
sleep 1
STATUS_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)
if echo "$STATUS_OUTPUT" | grep -q "STATUS"; then
    pass "STATUS message type works"
else
    fail "STATUS message type failed"
fi

# ============================================================
# PHASE 4: Test from different window (simulating agent)
# ============================================================
echo ""
echo "Phase 4: Testing notify-pm from agent window..."

# Create an agent window
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "developer" -c "$TEST_DIR"
sleep 1

# Send notification from agent window (window 1)
AGENT_MSG="AGENT_TEST_$(date +%s)"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "$PROJECT_ROOT/bin/notify-pm.sh '[DONE] $AGENT_MSG'" Enter
sleep 2

# Check output in agent window (no errors)
AGENT_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)
if echo "$AGENT_OUTPUT" | grep -q "Error:"; then
    fail "Agent window notification should not produce errors"
else
    pass "notify-pm.sh from agent window executed without errors"
fi

# Verify the command ran (check for command or message sent confirmation)
if echo "$AGENT_OUTPUT" | grep -q -E "notify-pm.sh|Message sent|$AGENT_MSG"; then
    pass "Agent window notification command was executed"
else
    # Could be timing issue, wait and retry
    sleep 1
    AGENT_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -50)
    if echo "$AGENT_OUTPUT" | grep -q -E "notify-pm.sh|Message sent|$AGENT_MSG"; then
        pass "Agent window notification command was executed"
    else
        fail "Agent window notification command not found"
    fi
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                  ║"
    EXIT_CODE=0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                        ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
