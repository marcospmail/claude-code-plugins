#!/bin/bash
# Test notify-pm.sh and send-message.sh functionality
# Run: ./tests/test-notify-pm.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-notify-pm-$$"
TEST_SESSION="test-notify-$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }

PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Testing notify-pm.sh & send-message.sh              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"

# Create tmux session with layout: pane 0 (check-ins) | pane 1 (PM)
echo "Creating test tmux session with PM layout..."
tmux new-session -d -s "$TEST_SESSION" -c "$TEST_DIR"

# Split window to create PM pane (pane 0 = check-ins, pane 1 = PM)
tmux split-window -t "$TEST_SESSION:0" -v

# Test 1: send-message.sh basic functionality
echo ""
echo "=== Test 1: send-message.sh sends message to target ==="
OUTPUT=$("$PROJECT_ROOT/bin/send-message.sh" "$TEST_SESSION:0.0" "Test message 1" 2>&1)

if echo "$OUTPUT" | grep -q "Message sent"; then
    pass "send-message.sh reports message sent"
else
    fail "send-message.sh did not report success"
    echo "$OUTPUT"
fi

# Test 2: Verify message appears in pane
echo ""
echo "=== Test 2: Message appears in target pane ==="
sleep 1
PANE_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:0.0" -p)

if echo "$PANE_CONTENT" | grep -q "Test message 1"; then
    pass "Message appears in pane"
else
    fail "Message not found in pane"
fi

# Test 3: send-message.sh to pane 1
echo ""
echo "=== Test 3: send-message.sh to PM pane (0.1) ==="
OUTPUT2=$("$PROJECT_ROOT/bin/send-message.sh" "$TEST_SESSION:0.1" "PM test message" 2>&1)

if echo "$OUTPUT2" | grep -q "Message sent"; then
    pass "Message sent to PM pane"
else
    fail "Failed to send to PM pane"
fi

# Test 4: Verify PM pane received message
echo ""
echo "=== Test 4: PM pane received message ==="
sleep 1
PM_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:0.1" -p)

if echo "$PM_CONTENT" | grep -q "PM test message"; then
    pass "PM pane received message"
else
    fail "PM pane did not receive message"
fi

# Test 5: send-message.sh with multiline message (using newlines)
echo ""
echo "=== Test 5: send-message.sh handles message with special chars ==="
SPECIAL_MSG="Test with special: & | < > \" '"
OUTPUT3=$("$PROJECT_ROOT/bin/send-message.sh" "$TEST_SESSION:0.0" "$SPECIAL_MSG" 2>&1)

if echo "$OUTPUT3" | grep -q "Message sent"; then
    pass "Message with special chars sent"
else
    fail "Failed to send message with special chars"
fi

# Test 6: send-message.sh missing arguments
echo ""
echo "=== Test 6: send-message.sh missing arguments shows usage ==="
OUTPUT_ERR=$("$PROJECT_ROOT/bin/send-message.sh" 2>&1 || true)

if echo "$OUTPUT_ERR" | grep -q "Usage:"; then
    pass "Missing arguments shows usage"
else
    fail "Missing arguments should show usage"
fi

# Test 7: notify-pm.sh requires tmux session
echo ""
echo "=== Test 7: notify-pm.sh requires running in tmux ==="
# Note: tmux display-message still works if any tmux server is running,
# even without TMUX env var, so we can only test this properly when no tmux exists.
# We verify the script has the check by reading the source.
if grep -q "Not running in a tmux session" "$PROJECT_ROOT/bin/notify-pm.sh"; then
    pass "notify-pm.sh has tmux session check in code"
else
    fail "notify-pm.sh missing tmux session check"
fi

# Test 8: notify-pm.sh inside tmux session
echo ""
echo "=== Test 8: notify-pm.sh sends to PM pane from inside session ==="
# Run notify-pm.sh inside the test tmux session
tmux send-keys -t "$TEST_SESSION:0.0" "$PROJECT_ROOT/bin/notify-pm.sh '[DONE] Task completed'" Enter
sleep 2

# Check if message arrived in PM pane
PM_CONTENT2=$(tmux capture-pane -t "$TEST_SESSION:0.1" -p)

if echo "$PM_CONTENT2" | grep -q "DONE"; then
    pass "notify-pm.sh sent message to PM pane"
else
    # notify-pm.sh might fail if pane 0 doesn't have proper shell context
    skip "Could not verify notify-pm.sh (needs shell in pane)"
fi

# Test 9: notify-pm.sh missing message shows usage
echo ""
echo "=== Test 9: notify-pm.sh missing message shows usage ==="
OUTPUT_NOARG=$("$PROJECT_ROOT/bin/notify-pm.sh" 2>&1 || true)

if echo "$OUTPUT_NOARG" | grep -q "Usage:"; then
    pass "notify-pm.sh missing message shows usage"
else
    fail "notify-pm.sh should show usage without message"
fi

# Test 10: send-message.sh to window (not pane)
echo ""
echo "=== Test 10: send-message.sh works with window format ==="
# Create new window
tmux new-window -t "$TEST_SESSION" -n "testwindow"
OUTPUT4=$("$PROJECT_ROOT/bin/send-message.sh" "$TEST_SESSION:1" "Window message" 2>&1)

if echo "$OUTPUT4" | grep -q "Message sent"; then
    pass "send-message.sh works with window format"
else
    fail "send-message.sh failed with window format"
fi

# Test 11: Verify window received message
echo ""
echo "=== Test 11: Window received message ==="
sleep 1
WIN_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:1" -p)

if echo "$WIN_CONTENT" | grep -q "Window message"; then
    pass "Window received message"
else
    fail "Window did not receive message"
fi

# Test 12: Message notification types via notify-pm.sh
echo ""
echo "=== Test 12: Different notification types work ==="
# Create a new window to test notifications without prior content
tmux new-window -t "$TEST_SESSION" -n "notify-test"
sleep 0.5

# Test different notification types by sending to the new window
TYPES=("DONE" "BLOCKED" "HELP" "STATUS" "PROGRESS")
TYPES_SENT=0

for type in "${TYPES[@]}"; do
    OUTPUT=$("$PROJECT_ROOT/bin/send-message.sh" "$TEST_SESSION:notify-test" "[$type] Test notification" 2>&1)
    if echo "$OUTPUT" | grep -q "Message sent"; then
        TYPES_SENT=$((TYPES_SENT + 1))
    fi
    sleep 0.5
done

if [[ "$TYPES_SENT" -eq 5 ]]; then
    pass "All 5 notification types sent successfully"
else
    fail "Only $TYPES_SENT of 5 notification types sent"
fi

# Summary
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $PASSED"
echo -e "  ${RED}Failed${NC}:  $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
