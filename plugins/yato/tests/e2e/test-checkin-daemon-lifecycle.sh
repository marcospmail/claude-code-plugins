#!/bin/bash
# test-checkin-daemon-lifecycle.sh
#
# E2E Test: Check-in daemon lifecycle (start, cancel, restart)
#
# Verifies:
# 1. Daemon starts via Claude running checkin_scheduler.py start
# 2. Daemon is cancelled via Claude running checkin_scheduler.py cancel
# 3. Daemon restarts after being cancelled
# 4. Daemon PID is tracked in checkins.json
# 5. Status command shows correct information
# 6. Pending entry has scheduled_for time
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-daemon-lifecycle"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-daemon-life-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Check-in Daemon Lifecycle"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

get_daemon_pid() {
    uv run python -c "
import json
import os
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        try:
            os.kill(pid, 0)
            print(pid)
        except:
            print('')
except:
    pass
" 2>/dev/null
}

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes for this test
    PID=$(get_daemon_pid)
    if [[ -n "$PID" ]]; then
        kill -9 "$PID" 2>/dev/null || true
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================
echo "Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test"

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 1
session: $SESSION_NAME
EOF

# Create initial empty checkins.json (no daemon)
echo '{"checkins": [], "daemon_pid": null}' > "$TEST_DIR/.workflow/001-test/checkins.json"

# Create tasks.json with a pending task
cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" YATO_PATH "$PROJECT_ROOT"

echo "  Test directory: $TEST_DIR"
echo "  Session: $SESSION_NAME"

# Start Claude in the session (skip permissions to avoid blocking on bash prompts)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter

# Wait for Claude to start and handle trust prompt
echo "  Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  No trust prompt found, continuing..."
    sleep 5
fi

echo "  Test environment ready"
echo ""

# ============================================================
# Test 1: Start daemon with incomplete tasks
# ============================================================
echo "Test 1: Starting daemon with incomplete tasks..."

# Ask Claude to run the checkin_scheduler start command
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/checkin_scheduler.py start 1 --note 'Test checkin' --target '$SESSION_NAME:0' --workflow '001-test'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill/tool trust prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

DAEMON_PID=$(get_daemon_pid)

if [[ -n "$DAEMON_PID" ]]; then
    pass "Daemon started with PID: $DAEMON_PID"
else
    fail "Daemon did not start"
fi

# ============================================================
# Test 2: Cancel daemon
# ============================================================
echo ""
echo "Test 2: Cancelling daemon..."

# Ask Claude to cancel the daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/checkin_scheduler.py cancel --workflow '001-test'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

NEW_PID=$(get_daemon_pid)
if [[ -z "$NEW_PID" ]]; then
    pass "Daemon stopped after cancel"
else
    fail "Daemon still running after cancel: $NEW_PID"
fi

# ============================================================
# Test 3: Daemon can restart after being stopped
# ============================================================
echo ""
echo "Test 3: Restarting daemon after stop..."

# Ask Claude to restart the daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/checkin_scheduler.py start 1 --note 'Restart test' --target '$SESSION_NAME:0' --workflow '001-test'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

DAEMON_PID=$(get_daemon_pid)
if [[ -n "$DAEMON_PID" ]]; then
    pass "Daemon restarted with PID: $DAEMON_PID"
else
    fail "Daemon did not restart"
fi

# Check for resumed entry
RESUMED_COUNT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    resumed = [c for c in data.get('checkins', []) if c.get('status') == 'resumed']
    print(len(resumed))
except:
    print(0)
" 2>/dev/null)

if [[ "$RESUMED_COUNT" -ge 1 ]]; then
    pass "Resumed entry added to checkins.json"
else
    fail "No resumed entry found (expected after stop+restart)"
fi

# ============================================================
# Test 4: Status command shows correct information
# ============================================================
echo ""
echo "Test 4: Checking status command output..."

# Ask Claude to run the status command
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/checkin_scheduler.py status --workflow '001-test'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

# Capture the output
STATUS_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

if echo "$STATUS_OUTPUT" | grep -q "Daemon running: True"; then
    pass "Status shows daemon running"
else
    fail "Status should show daemon running"
fi

if echo "$STATUS_OUTPUT" | grep -q "Incomplete tasks: 1"; then
    pass "Status shows correct incomplete task count"
else
    fail "Status should show 1 incomplete task"
fi

if echo "$STATUS_OUTPUT" | grep -q "Interval: 1"; then
    pass "Status shows correct interval"
else
    fail "Status should show interval"
fi

# ============================================================
# Test 5: Verify pending entry has scheduled_for time
# ============================================================
echo ""
echo "Test 5: Checking pending entry has scheduled_for..."

SCHEDULED_FOR=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data.get('checkins', []) if c.get('status') == 'pending']
    if pending:
        print(pending[-1].get('scheduled_for', ''))
except:
    pass
" 2>/dev/null)

if [[ -n "$SCHEDULED_FOR" ]] && [[ "$SCHEDULED_FOR" != "None" ]]; then
    pass "Pending entry has scheduled_for: $SCHEDULED_FOR"
else
    fail "Pending entry missing scheduled_for"
fi

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
