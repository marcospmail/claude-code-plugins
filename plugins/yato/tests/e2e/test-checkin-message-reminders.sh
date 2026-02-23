#!/bin/bash
# test-checkin-message-reminders.sh
#
# E2E Test: Check-in message contains PM reminders
#
# Verifies that the REAL check-in daemon generates correct messages:
# 1. Check-in message contains "Time for check-in" with task count
# 2. Check-in message includes REMINDER about updating tasks.json
# 3. Check-in message includes stacked suffix from defaults.conf
# 4. Message is actually sent to the target pane

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-message-reminders"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-checkin-msg-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

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
    # Kill any daemon processes for this test
    if [[ -f "$TEST_DIR/.workflow/001-test-workflow/checkins.json" ]]; then
        DAEMON_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json') as f:
        print(json.load(f).get('daemon_pid', ''))
except: pass
" 2>/dev/null)
        if [[ -n "$DAEMON_PID" ]]; then
            kill "$DAEMON_PID" 2>/dev/null || true
        fi
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
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
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

# Verify session created
if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created: $SESSION_NAME"
echo "Test directory: $TEST_DIR"
echo ""

# ============================================================
# Phase 1: Start real check-in daemon
# ============================================================
echo "Phase 1: Starting real check-in daemon..."

# Start the daemon with 1-minute interval targeting the session pane
# Must run from project dir so find_project_root() finds .workflow/
# YATO_PATH ensures daemon finds config/defaults.conf for suffix stacking
cd "$TEST_DIR"
YATO_PATH="$PROJECT_ROOT" TMUX_SOCKET="$TMUX_SOCKET" uv run --directory "$PROJECT_ROOT" python lib/checkin_scheduler.py start 1 \
    --note "Test checkin" \
    --target "$SESSION_NAME:0" \
    --workflow "001-test-workflow" 2>&1

# Verify daemon started by checking checkins.json for daemon_pid
sleep 2
DAEMON_PID=$(python3 -c "
import json
with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json') as f:
    data = json.load(f)
print(data.get('daemon_pid', ''))
" 2>/dev/null)

if [[ -n "$DAEMON_PID" ]] && kill -0 "$DAEMON_PID" 2>/dev/null; then
    pass "Check-in daemon started (PID: $DAEMON_PID)"
else
    fail "Check-in daemon not running"
fi

echo ""

# ============================================================
# Phase 2: Wait for daemon to fire and verify message
# ============================================================
echo "Phase 2: Waiting for check-in to fire (1-minute interval + buffer)..."

# Daemon fires after interval_minutes (1 min) + up to DAEMON_POLL_INTERVAL (10s)
sleep 75

# Capture target pane output
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p -S -100 2>/dev/null)

echo "Debug - Captured output:"
echo "$OUTPUT" | head -20
echo ""

if echo "$OUTPUT" | grep -qi "Time for check-in"; then
    pass "Message contains 'Time for check-in'"
else
    fail "Message missing 'Time for check-in'"
fi

if echo "$OUTPUT" | grep -qi "tasks remaining\|tasks.json.*broken"; then
    pass "Message contains task count info"
else
    fail "Message missing task count info"
fi

# ============================================================
# Phase 3: Verify REMINDER content in message
# ============================================================
echo ""
echo "Phase 3: Verifying REMINDER content..."

if echo "$OUTPUT" | grep -qi "REMINDER"; then
    pass "Message contains REMINDER"
else
    fail "Message missing REMINDER"
fi

if echo "$OUTPUT" | grep -qi "update tasks.json\|tasks.json updated"; then
    pass "Message mentions updating tasks.json"
else
    fail "Message missing tasks.json update instruction"
fi

# ============================================================
# Phase 4: Verify stacked suffix from defaults.conf
# ============================================================
echo ""
echo "Phase 4: Verifying stacked suffix from defaults.conf..."

# CHECKIN_TO_PM_SUFFIX should be appended to the message
if echo "$OUTPUT" | grep -qi "distribute work\|don.*do work yourself\|MUST ONLY do PM work"; then
    pass "Suffix contains delegation reminder"
else
    fail "Suffix missing delegation reminder (from CHECKIN_TO_PM_SUFFIX)"
fi

if echo "$OUTPUT" | grep -qi "Read your identity.yml\|Read your instructions.md\|Read your constraints.md"; then
    pass "Suffix contains file reading reminders"
else
    fail "Suffix missing file reading reminders"
fi

# ============================================================
# Phase 5: Test schedule-checkin.sh directly
# ============================================================
echo ""
echo "Phase 5: Testing schedule-checkin.sh directly..."

SCHEDULE_OUTPUT=$(cd "$TEST_DIR" && TMUX_SOCKET="$TMUX_SOCKET" bash "$BIN_DIR/schedule-checkin.sh" 1 'Test note' "$SESSION_NAME:0" 2>&1)

if echo "$SCHEDULE_OUTPUT" | grep -qi "Daemon started\|Starting check-in daemon\|Scheduled\|Check-in\|already running"; then
    pass "schedule-checkin.sh runs without error"
else
    fail "schedule-checkin.sh may have issues: $SCHEDULE_OUTPUT"
fi

# ============================================================
# Phase 6: Verify send-message.sh with multiline content
# ============================================================
echo ""
echo "Phase 6: Testing send-message.sh with multiline content..."

# Clear the pane first
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "clear" Enter
sleep 1

# Send multiline message directly
TMUX_SOCKET="$TMUX_SOCKET" "$BIN_DIR/send-message.sh" "$SESSION_NAME:0" "Line 1: Header
Line 2: Content
Line 3: More content" 2>/dev/null

sleep 2

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p -S -20 2>/dev/null)

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
