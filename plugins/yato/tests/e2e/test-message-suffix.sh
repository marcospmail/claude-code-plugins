#!/bin/bash
# test-message-suffix.sh
#
# E2E Test: PM_TO_AGENTS_SUFFIX Configuration Feature
#
# Verifies that messages sent via the Python send_message() function append a
# configurable suffix from config/defaults.conf to every message delivered to agents.
# Uses a real Claude Code session to invoke the send_message Python function.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="message-suffix"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-suffix-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: PM_TO_AGENTS_SUFFIX Configuration Feature              ║"
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

# Helper: send a command to Claude and approve the permission prompt
send_to_claude() {
    local cmd="$1"
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "$cmd"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" Enter
    sleep 15  # Wait for Claude to show permission prompt

    # Approve the permission prompt (press Enter to accept "Yes")
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" Enter
    sleep 10  # Wait for command to execute
}

# Setup test environment
echo "Setting up test environment..."
mkdir -p "$TEST_DIR/config"

# Create config with PM_TO_AGENTS_SUFFIX (use a plain text marker without special regex/glob chars)
EXPECTED_SUFFIX=" --YATO_SUFFIX_MARKER--"
cat > "$TEST_DIR/config/defaults.conf" <<EOF
# Test configuration for PM_TO_AGENTS_SUFFIX feature
PM_TO_AGENTS_SUFFIX="$EXPECTED_SUFFIX"
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
EOF

# Create a dummy file so Claude trusts the directory
echo "// test project" > "$TEST_DIR/index.js"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# Create tmux session with two windows: Claude (window 0) and receiver (window 1)
echo "Starting tmux session and Claude..."
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "claude" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "receiver" -c "$TEST_DIR"

# Disable flow control in receiver
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "stty -ixon" Enter
sleep 1

# Start Claude in window 0
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" Enter
    sleep 15
else
    echo "No trust prompt found, continuing..."
    sleep 5
fi

echo ""
echo "Testing PM_TO_AGENTS_SUFFIX feature..."
echo ""

# ============================================================
# Test 1: Send message via Python and verify suffix is appended
# ============================================================
echo "Test 1: Verify suffix is appended to message"
MSG1="HELLO_AGENT_$(date +%s)"

# Ask Claude to run the send_message function targeting the receiver window
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:1', '$MSG1')\""

# Debug: show what Claude did
echo "Debug - Claude output after Test 1:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p | tail -15
echo ""

# Capture receiver pane output
OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

echo "Debug - Receiver pane content:"
echo "$OUTPUT1" | tail -10
echo ""

# Verify original message is present (use -F for fixed string matching)
if echo "$OUTPUT1" | grep -Fq "$MSG1"; then
    pass "Original message delivered to receiver"
else
    fail "Original message not found in receiver"
    echo "     Expected: $MSG1"
fi

# Verify suffix is appended
if echo "$OUTPUT1" | grep -Fq "$EXPECTED_SUFFIX"; then
    pass "PM_TO_AGENTS_SUFFIX appended to message"
else
    fail "PM_TO_AGENTS_SUFFIX not found in receiver output"
    echo "     Expected suffix: $EXPECTED_SUFFIX"
fi

# Verify they appear together (message + suffix on same line)
if echo "$OUTPUT1" | grep -F "$MSG1" | grep -Fq "$EXPECTED_SUFFIX"; then
    pass "Message and suffix appear together correctly"
else
    fail "Message and suffix not properly combined"
fi

# ============================================================
# Test 2: Send a second message to verify consistency
# ============================================================
echo ""
echo "Test 2: Verify suffix added to multiple messages"
MSG2="SECOND_MSG_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:1', '$MSG2')\""

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

if echo "$OUTPUT2" | grep -F "$MSG2" | grep -Fq "$EXPECTED_SUFFIX"; then
    pass "Suffix consistently appended to second message"
else
    fail "Suffix not appended to second message"
    echo "Debug - Receiver pane:"
    echo "$OUTPUT2" | tail -10
fi

# ============================================================
# Test 3: Empty suffix should not add anything
# ============================================================
echo ""
echo "Test 3: Verify empty suffix configuration works"

# Update config to empty suffix
cat > "$TEST_DIR/config/defaults.conf" <<'EOF'
PM_TO_AGENTS_SUFFIX=""
DEFAULT_SESSION="test"
EOF

MSG3="EMPTY_SUFFIX_MSG_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:1', '$MSG3')\""

OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

if echo "$OUTPUT3" | grep -Fq "$MSG3"; then
    pass "Message delivered with empty suffix"
else
    fail "Message with empty suffix not delivered"
fi

# The line containing MSG3 should NOT have the old suffix marker
MSG3_LINE=$(echo "$OUTPUT3" | grep -F "$MSG3" | tail -1)
if echo "$MSG3_LINE" | grep -Fq "$EXPECTED_SUFFIX"; then
    fail "Old suffix marker should not appear with empty suffix config"
else
    pass "Empty suffix correctly adds nothing to message"
fi

# Results
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)                                    ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                          ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 1
fi
