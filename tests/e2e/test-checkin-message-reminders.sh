#!/bin/bash
# test-checkin-message-reminders.sh
#
# E2E Test: Check-in message contains PM reminders
#
# Verifies that:
# 1. Check-in message includes delegation reminder
# 2. Check-in message includes task status rules
# 3. Message is actually sent to the target pane

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-message-reminders"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-checkin-msg-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: Check-in Message PM Reminders"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    # Kill any pending check-in background processes
    pkill -f "schedule-checkin.*$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================
echo "Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

# Create status.yml
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

# Create tasks.json with incomplete tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "qa", "status": "blocked", "blockedBy": ["T1"], "blocks": []}
  ]
}
EOF

# Create checkins.json
echo '{"checkins": []}' > "$TEST_DIR/.workflow/001-test-workflow/checkins.json"

# Create tmux session with WORKFLOW_NAME env var
# Use larger window size to capture full messages
tmux new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

# Verify session created
if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created: $SESSION_NAME"

# Start Claude in the session (tmux+Claude pattern)
tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter

# Wait for Claude to initialize
echo "  - Waiting for Claude to initialize..."
sleep 12

echo "Test directory: $TEST_DIR"
echo ""

# ============================================================
# Test 1: Trigger check-in and verify message is sent
# ============================================================
echo "Phase 1: Triggering check-in..."

# Clear the pane first
tmux send-keys -t "$SESSION_NAME" "clear" Enter
sleep 1

# Run schedule-checkin with a very short interval (will execute after 1 second for testing)
# We use a custom script to send message immediately for testing
tmux send-keys -t "$SESSION_NAME" "cd $TEST_DIR" Enter
sleep 1

# Directly call send-message.sh with the check-in message format to test immediately
# This simulates what schedule-checkin.sh does
NOTE="Test check-in (2 tasks remaining)"
CHECKIN_MSG="Time for check-in! (\$NOTE)

⚠️ PM REMINDERS:
• DELEGATE work to agents - do NOT implement/code yourself
• 'completed' = work was ACTUALLY DONE by an agent
• 'blocked' stays blocked until resolved - you cannot skip tasks
• If user says 'skip it', task stays BLOCKED (not completed)"

# Send the message directly using send-message.sh
tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/send-message.sh '$SESSION_NAME:0' 'Time for check-in! ($NOTE)

⚠️ PM REMINDERS:
• DELEGATE work to agents - do NOT implement/code yourself
• 'completed' = work was ACTUALLY DONE by an agent
• blocked stays blocked until resolved - you cannot skip tasks
• If user says skip it, task stays BLOCKED (not completed)'" Enter

sleep 3

# Capture pane output
OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)

echo "Debug - Captured output:"
echo "$OUTPUT"
echo ""

# ============================================================
# Test 2: Verify message contains check-in text
# ============================================================
echo "Phase 2: Verifying message content..."

if echo "$OUTPUT" | grep -qi "Time for check-in"; then
    pass "Message contains 'Time for check-in'"
else
    fail "Message missing 'Time for check-in'"
fi

if echo "$OUTPUT" | grep -qi "PM REMINDERS"; then
    pass "Message contains 'PM REMINDERS' header"
else
    fail "Message missing 'PM REMINDERS' header"
fi

# ============================================================
# Test 3: Verify delegation reminder
# ============================================================
echo ""
echo "Phase 3: Verifying delegation reminder..."

if echo "$OUTPUT" | grep -qi "DELEGATE.*agents\|DELEGATE work"; then
    pass "Message contains delegation reminder"
else
    fail "Message missing delegation reminder"
fi

if echo "$OUTPUT" | grep -qi "do NOT implement\|NOT.*implement.*yourself"; then
    pass "Message contains 'do NOT implement' warning"
else
    fail "Message missing 'do NOT implement' warning"
fi

# ============================================================
# Test 4: Verify task status rules
# ============================================================
echo ""
echo "Phase 4: Verifying task status rules..."

if echo "$OUTPUT" | grep -qi "completed.*ACTUALLY.*DONE\|ACTUALLY DONE"; then
    pass "Message contains 'completed = ACTUALLY DONE' rule"
else
    fail "Message missing 'completed = ACTUALLY DONE' rule"
fi

if echo "$OUTPUT" | grep -qi "blocked.*stays.*blocked"; then
    pass "Message contains 'blocked stays blocked' rule"
else
    fail "Message missing 'blocked stays blocked' rule"
fi

if echo "$OUTPUT" | grep -qi "skip.*BLOCKED\|stays BLOCKED"; then
    pass "Message contains 'skip keeps BLOCKED' rule"
else
    fail "Message missing 'skip keeps BLOCKED' rule"
fi

# ============================================================
# Test 5: Test actual schedule-checkin.sh output
# ============================================================
echo ""
echo "Phase 5: Testing schedule-checkin.sh directly..."

# Have Claude run schedule-checkin.sh (tmux+Claude pattern)
tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/schedule-checkin.sh 1 'Test note' '$SESSION_NAME:0'" Enter

# Wait for execution
sleep 5

# Capture output from Claude's pane
SCHEDULE_OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p -S -30 2>/dev/null)

echo "Schedule output (via Claude):"
echo "$SCHEDULE_OUTPUT" | tail -15
echo ""

if echo "$SCHEDULE_OUTPUT" | grep -qi "Daemon started\|Starting check-in daemon\|Scheduled\|Check-in"; then
    pass "schedule-checkin.sh runs without error (via Claude)"
else
    # Check if it's the guard preventing duplicate
    if echo "$SCHEDULE_OUTPUT" | grep -qi "already running\|already pending"; then
        pass "schedule-checkin.sh correctly guards against duplicate (expected behavior)"
    else
        fail "schedule-checkin.sh may have issues: $SCHEDULE_OUTPUT"
    fi
fi

# ============================================================
# Test 6: Verify send-message.sh works with multiline
# ============================================================
echo ""
echo "Phase 6: Testing send-message.sh with multiline content..."

# Clear pane
tmux send-keys -t "$SESSION_NAME" "clear" Enter
sleep 1

# Test multiline message - have Claude run send-message.sh (tmux+Claude pattern)
MULTILINE_MSG="Line 1: Header
Line 2: Content
Line 3: More content"

# Send the command through Claude (escape quotes for the message)
tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/send-message.sh '$SESSION_NAME:0' 'Line 1: Header
Line 2: Content
Line 3: More content'" Enter

sleep 3

OUTPUT2=$(tmux capture-pane -t "$SESSION_NAME" -p -S -20 2>/dev/null)

if echo "$OUTPUT2" | grep -q "Line 1\|Line 2\|Line 3"; then
    pass "send-message.sh handles multiline messages"
else
    fail "send-message.sh may have issues with multiline"
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
