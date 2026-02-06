#!/bin/bash
# test-loop-cancel-project-dir.sh
# Description: Tests that /loop --cancel correctly finds loops when run from the project directory
#
# Bug being tested:
#   When running /loop --cancel in a project directory, Claude would run:
#     cd ~/dev/tools/yato && uv run yato loop list --status running
#   WITHOUT the --project parameter, so it couldn't find loops created in
#   the project's .workflow/loops/ directory.
#
# Fix verified:
#   SKILL.md updated to ALWAYS capture PROJECT_DIR=$(pwd) BEFORE cd'ing to yato:
#     PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop list --status running --project "$PROJECT_DIR"
#
# Pattern: Based on test-loop-skill.sh - uses tmux + interactive Claude

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="loop-cancel-project-dir"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Loop Cancel with --project parameter"
echo "======================================================================"
echo "  Bug: /loop --cancel didn't pass --project, couldn't find loops"
echo "  Fix: SKILL.md captures PROJECT_DIR=$(pwd) before cd to yato"
echo "======================================================================"
echo

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

echo "  Test directory: $TEST_DIR"
echo "  Session: $SESSION_NAME"
echo

echo "Starting tmux session and Claude..."
# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "Waiting for Claude to start (checking for trust prompt)..."
sleep 8

# Check for trust prompt and send Enter
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  No trust prompt found, continuing..."
    sleep 5
fi
echo

# ============================================================
# Test 1: Start a loop in the test directory
# ============================================================
echo "Test 1: Starting a loop with --times 10 (long running)..."

# Send text first, then Enter separately (required for Claude's TUI)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/loop monitor system status --times 10"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30  # Wait for Claude to process skill and create loop

# Debug: show what Claude did
echo "  Debug - Claude output after starting loop:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p | tail -15
echo

# Check for loop folder creation in TEST_DIR (not in yato directory)
LOOP_FOLDER=$(ls -d "$TEST_DIR/.workflow/loops/"* 2>/dev/null | head -1)
if [[ -n "$LOOP_FOLDER" ]] && [[ -f "$LOOP_FOLDER/meta.json" ]]; then
    pass "Loop folder created in correct project directory"

    # Verify the loop is running (or has run)
    SHOULD_CONTINUE=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('should_continue', False))" 2>/dev/null)
    EXEC_COUNT=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('execution_count', 0))" 2>/dev/null)
    if [[ "$SHOULD_CONTINUE" == "True" ]] || [[ "$EXEC_COUNT" -ge 1 ]]; then
        pass "Loop is active (should_continue=$SHOULD_CONTINUE, execution_count=$EXEC_COUNT)"
    else
        fail "Loop not active, should_continue=$SHOULD_CONTINUE, execution_count=$EXEC_COUNT"
    fi
else
    fail "Loop folder not created in project directory ($TEST_DIR/.workflow/loops/)"
    echo "  Debug - Full Claude output:"
    tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 | tail -30

    # Check if loop was mistakenly created in yato directory
    if ls -d "$PROJECT_ROOT/.workflow/loops/"* 2>/dev/null | head -1; then
        fail "CRITICAL: Loop was created in yato directory instead of project directory!"
    fi
fi

# ============================================================
# Test 2: Cancel the loop using /loop --cancel
# This tests that --project parameter is correctly passed
# ============================================================
echo
echo "Test 2: Cancelling loop with /loop --cancel..."
echo "  (This is the critical test - verifies --project parameter is passed)"

# Send Escape first to try to interrupt any ongoing operation
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Escape
sleep 2

# Send /loop --cancel to Claude via tmux
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/loop --cancel"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 45  # Wait for Claude to process skill and show AskUserQuestion or list

# Capture full output for verification
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

# Debug: show what Claude did
echo "  Debug - Claude output after /loop --cancel:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 | tail -25
echo

# CRITICAL TEST: Did Claude find the loop?
# The fix ensures Claude runs: PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop list --project "$PROJECT_DIR"
#
# Success indicators (any of these means --project worked):
# - AskUserQuestion shown with loop options
# - Loop info displayed (e.g., "001-monitor-system-status")
# - "Cancel all loops" option shown
#
# Failure indicator (means --project was NOT passed):
# - "No active loops to cancel" message (exact CLI output)

LOOP_FOUND=false

# Check if AskUserQuestion was shown with loop options (primary success indicator)
if echo "$OUTPUT" | grep -qi "monitor.*system\|001-monitor\|Cancel all loops\|which loop.*cancel"; then
    pass "Claude found the loop (AskUserQuestion shown with loop options)"
    LOOP_FOUND=true

    # Select the first option (the loop we created)
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15

    # May need another Enter if there's another prompt
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 10
elif echo "$OUTPUT" | grep -qi "cancelled\|canceled\|Loop cancelled"; then
    # Claude may have auto-cancelled if only one loop
    pass "Claude found and cancelled the loop directly"
    LOOP_FOUND=true
fi

# Check for the specific failure message (only fail if loop was NOT found above)
if [[ "$LOOP_FOUND" == "false" ]]; then
    # Look for the exact error message from the CLI
    if echo "$OUTPUT" | grep -qi "No active loops to cancel\|No loops found"; then
        fail "CRITICAL BUG: Claude said 'No loops found' but loop exists at $LOOP_FOLDER"
        echo "  The --project parameter was likely NOT passed to the loop list command."
    else
        fail "Could not determine if loop was found - check debug output above"
    fi
fi

# Optional: Check if --project was visible in command output
if echo "$OUTPUT" | grep -q '\-\-project'; then
    echo "  Note: Verified --project parameter was used in command"
fi

# Debug: show after selection
echo "  Debug - After selection:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p | tail -15
echo

# ============================================================
# Test 3: Verify loop was actually cancelled
# ============================================================
echo
echo "Test 3: Verifying loop was cancelled..."

if [[ -n "$LOOP_FOLDER" ]] && [[ -f "$LOOP_FOLDER/meta.json" ]]; then
    SHOULD_CONTINUE=$(python3 -c "import json; print(json.load(open('$LOOP_FOLDER/meta.json')).get('should_continue', True))" 2>/dev/null)
    if [[ "$SHOULD_CONTINUE" == "False" ]]; then
        pass "Loop cancelled successfully (should_continue=False in meta.json)"
    else
        fail "Loop may not be cancelled, should_continue=$SHOULD_CONTINUE"
    fi
else
    fail "Loop folder not found for cancel verification"
fi

# ============================================================
# Results
# ============================================================
echo
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    echo
    echo "  Summary:"
    echo "    - Loop was created in correct project directory ($TEST_DIR)"
    echo "    - /loop --cancel found the loop using --project parameter"
    echo "    - Loop was successfully cancelled"
    echo
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    echo
    echo "  If 'No loops found' error occurred, the bug is NOT fixed."
    echo "  Check that SKILL.md captures PROJECT_DIR=$(pwd) BEFORE cd'ing to yato."
    echo
    exit 1
fi
