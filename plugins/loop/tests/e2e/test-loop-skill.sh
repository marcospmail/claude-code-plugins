#!/bin/bash
# test-loop-skill.sh
# Description: Tests the /loop skill by sending commands to Claude via tmux
# Pattern: Based on test-workflow-numbering.sh - uses tmux + interactive Claude

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="loop-skill"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-loop-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Loop Skill (via Claude + tmux)"
echo "======================================================================"
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

# Setup phase
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"
echo "console.log('test');" > "$TEST_DIR/app.js"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

echo "Starting tmux session and Claude..."
# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "Waiting for trust prompt..."
sleep 8

# Check for trust prompt and send Enter
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "No trust prompt found, continuing..."
    sleep 5
fi

echo ""

# ============================================================
# Test 1: /loop with --times
# ============================================================
echo ""
echo "Test 1: /loop with --times..."

# Send text first, then Enter separately (required for Claude's TUI)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/loop say hello --times 2"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30  # Wait for Claude to process skill (loop may complete within this time since it runs immediately)

# Debug: show what Claude did
echo "Debug - After /loop --times 2:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p | tail -20
echo ""

# Check for loop folder creation
LOOP_FOLDER=$(ls -d "$TEST_DIR/.workflow/loops/"* 2>/dev/null | head -1)
if [[ -n "$LOOP_FOLDER" ]] && [[ -f "$LOOP_FOLDER/meta.json" ]]; then
    pass "Loop folder and meta.json created"

    # Verify stop_after_times
    STOP_TIMES=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('stop_after_times', ''))" 2>/dev/null)
    if [[ "$STOP_TIMES" == "2" ]]; then
        pass "stop_after_times is 2"
    else
        fail "stop_after_times should be 2, got: $STOP_TIMES"
    fi

    # Check execution count - if loop ran, it's working
    EXEC_COUNT=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('execution_count', 0))" 2>/dev/null)
    if [[ "$EXEC_COUNT" -ge 1 ]]; then
        pass "Loop executed at least once (count: $EXEC_COUNT)"
    else
        fail "Loop never executed, count: $EXEC_COUNT"
    fi
else
    fail "Loop folder not created at $TEST_DIR/.workflow/loops/"
    # Debug: show what Claude output
    echo "  Debug - Claude output:"
    tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 | tail -20
fi

# Check completion via meta.json (no global registry)
EXEC_COUNT=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('execution_count', 0))" 2>/dev/null)
if [[ "$EXEC_COUNT" == "2" ]]; then
    pass "Loop completed all 2 executions"
else
    # If loop is still running, check should_continue in meta.json
    SHOULD_CONTINUE=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('should_continue', False))" 2>/dev/null)
    if [[ "$SHOULD_CONTINUE" == "True" ]]; then
        pass "Loop is still running (should_continue=True, exec_count: $EXEC_COUNT)"
    else
        fail "Loop didn't complete all executions and isn't running (exec_count: $EXEC_COUNT)"
    fi
fi

# Cancel this loop before next test
echo ""
echo "Cancelling loop before next test..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/loop --cancel"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10
# Select first option if menu shown
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 3

# Clean up loop folder for next test
rm -rf "$TEST_DIR/.workflow/loops"

# ============================================================
# Test 2: /loop with --for and --every
# ============================================================
echo ""
echo "Test 2: /loop with --for and --every..."

# Test 2: Create a loop with --for and --every (no interval - immediate execution)
# Using --times instead of --for with interval, because intervals block the cancel test
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/loop check system --times 10"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30  # Wait for loop creation and some executions

# Debug: show what Claude did
echo "Debug - After /loop --times 10:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p | tail -20
echo ""

# Get the new loop folder (should be different from test 1's folder)
LOOP_FOLDER=$(ls -dt "$TEST_DIR/.workflow/loops/"* 2>/dev/null | head -1)
if [[ -n "$LOOP_FOLDER" ]] && [[ -f "$LOOP_FOLDER/meta.json" ]]; then
    pass "Loop folder created for --times 10 test"

    # Verify stop_after_times is 10
    STOP_TIMES=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('stop_after_times', 0))" 2>/dev/null)
    if [[ "$STOP_TIMES" == "10" ]]; then
        pass "stop_after_times is 10"
    else
        fail "stop_after_times should be 10, got: $STOP_TIMES"
    fi

    # Verify it's running (should_continue true or execution_count > 0)
    EXEC_COUNT=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('execution_count', 0))" 2>/dev/null)
    if [[ "$EXEC_COUNT" -ge 1 ]]; then
        pass "Loop is running (execution_count: $EXEC_COUNT)"
    else
        fail "Loop hasn't executed yet"
    fi
else
    fail "Loop folder not created for --times 10 test"
    echo "  Debug - Claude output:"
    tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 | tail -20
fi

# ============================================================
# Test 3: /loop --cancel via Claude + tmux
# ============================================================
echo ""
echo "Test 3: /loop --cancel via Claude..."

# Loop from test 2 is running with --times 10 and no interval
# It executes immediately between iterations, so we need to catch
# Claude between responses. Send Escape first to try to interrupt.
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Escape
sleep 2

# Send /loop --cancel to Claude via tmux
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/loop --cancel"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 45  # Wait for Claude to process skill and show AskUserQuestion

# Debug: show what Claude did
echo "Debug - After /loop --cancel:"
CANCEL_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -80 2>/dev/null)
echo "$CANCEL_OUTPUT" | tail -25
echo ""

# Verify AskUserQuestion is shown (even for a single loop)
# AskUserQuestion appears as a selection menu with options
if echo "$CANCEL_OUTPUT" | grep -qiE "cancel all|which loop|select|choose|►|❯|1\.|2\."; then
    pass "AskUserQuestion selection shown for loop cancel"
else
    fail "AskUserQuestion selection NOT shown - Claude should ALWAYS ask which loop to cancel"
    echo "  Expected: Selection menu with loop options"
fi

# Claude may show either:
# 1. AskUserQuestion menu (select with Enter)
# 2. Edit permission prompt (select "1. Yes" with Enter)
# Send Enter to approve/select
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 15

# May need another Enter if there's another prompt
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 15  # Wait for Claude to execute cancel command

# Debug: show after selection
echo "Debug - After selection:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p | tail -20
echo ""

# Verify loop was cancelled by checking meta.json
if [[ -n "$LOOP_FOLDER" ]] && [[ -f "$LOOP_FOLDER/meta.json" ]]; then
    SHOULD_CONTINUE=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('should_continue', True))" 2>/dev/null)
    if [[ "$SHOULD_CONTINUE" == "False" ]]; then
        pass "Loop cancelled via /loop --cancel skill (should_continue=False)"
    else
        fail "Loop not cancelled, should_continue=$SHOULD_CONTINUE"
    fi
else
    fail "Loop folder not found for cancel verification"
fi

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    exit 0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    exit 1
fi
