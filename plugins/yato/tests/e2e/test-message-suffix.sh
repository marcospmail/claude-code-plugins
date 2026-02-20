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

# Helper: run a Python command directly (no Claude CLI needed)
run_python() {
    local python_code="$1"
    cd "$PROJECT_ROOT" && YATO_PATH="$TEST_DIR" TMUX_SOCKET="$TMUX_SOCKET" uv run python -c "$python_code"
    sleep 2  # Allow tmux pane to receive the message
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

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# Create tmux session with receiver window (no Claude needed)
echo "Starting tmux session..."
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "receiver" -c "$TEST_DIR"

# Disable flow control in receiver
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "stty -ixon" Enter
sleep 1

echo ""
echo "Testing PM_TO_AGENTS_SUFFIX feature..."
echo ""

# ============================================================
# Test 1: Send message via Python and verify suffix is appended
# ============================================================
echo "Test 1: Verify suffix is appended to message"
MSG1="HELLO_AGENT_$(date +%s)"

run_python "from lib.tmux_utils import send_message; send_message('$SESSION_NAME:0', '$MSG1')"

# Capture receiver pane output
OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

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

# Verify both appear in output (suffix is on separate line per design, separated by \n\n)
if echo "$OUTPUT1" | grep -Fq "$MSG1" && echo "$OUTPUT1" | grep -Fq "$EXPECTED_SUFFIX"; then
    pass "Message and suffix both present in output"
else
    fail "Message and suffix not both present in output"
fi

# ============================================================
# Test 2: Send a second message to verify consistency
# ============================================================
echo ""
echo "Test 2: Verify suffix added to multiple messages"
MSG2="SECOND_MSG_$(date +%s)"

run_python "from lib.tmux_utils import send_message; send_message('$SESSION_NAME:0', '$MSG2')"

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

if echo "$OUTPUT2" | grep -Fq "$MSG2" && echo "$OUTPUT2" | grep -Fq "$EXPECTED_SUFFIX"; then
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

run_python "from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:0', '$MSG3')"

OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

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
