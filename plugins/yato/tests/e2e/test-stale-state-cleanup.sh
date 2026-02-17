#!/bin/bash
# test-stale-state-cleanup.sh
#
# E2E Test: Stale state cleanup when daemon dies with all tasks complete
#
# Verifies:
# 1. Dead daemon + all tasks complete → cleanup_stale_state() is invoked
# 2. daemon_pid is cleared to null in checkins.json
# 3. Pending check-in entries are marked as cancelled
# 4. 'stale-state-cleaned' audit entry is added to checkins.json
# 5. status.yml is updated from 'in-progress' to 'completed' with completed_at
# 6. No cleanup when daemon_pid is already null (no stale state)
# 7. No cleanup when daemon is alive (alive daemon → no action)
# 8. No cleanup when incomplete tasks exist (restart path instead)
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="stale-state-cleanup"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-stale-st-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Stale State Cleanup (Dead Daemon + All Tasks Complete)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes for this test
    if [[ -f "$TEST_DIR/.workflow/001-test/checkins.json" ]]; then
        PID=$(uv run python -c "
import json, os
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        try:
            os.kill(pid, 0)
            print(pid)
        except:
            pass
except:
    pass
" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/tasks-change-hook.py"

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================
echo "Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test"

# Create tmux session
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" YATO_PATH "$PROJECT_ROOT"

if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    pass "Tmux session created"
else
    fail "Failed to create tmux session"
    exit 1
fi

echo "  Test directory: $TEST_DIR"
echo "  Session: $SESSION_NAME"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "unset CLAUDECODE && claude --dangerously-skip-permissions" Enter

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
# Test 1: Dead daemon + all tasks complete → stale state cleaned
# ============================================================
echo "Test 1: Dead daemon + all tasks complete → cleanup stale state..."

# Setup: stale daemon_pid (dead process), pending checkin, in-progress status
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "100", "status": "pending", "scheduled_for": "2024-01-01T12:00:00", "note": "Stale pending", "target": "test:0", "created_at": "2024-01-01T11:55:00"},
    {"id": "99", "status": "done", "completed_at": "2024-01-01T11:50:00", "note": "Previous checkin", "target": "test:0", "created_at": "2024-01-01T11:45:00"}
  ],
  "daemon_pid": 999999
}
EOF

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "qa", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: $SESSION_NAME
EOF

# Run the hook simulating a tasks.json edit
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'STALE_HOOK_DONE_1'"
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

# Verify: daemon_pid cleared to null
DAEMON_PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    print('null' if pid is None else str(pid))
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null)

if [[ "$DAEMON_PID" == "null" ]]; then
    pass "daemon_pid cleared to null"
else
    fail "daemon_pid should be null, got: $DAEMON_PID"
fi

# Verify: pending entry cancelled
PENDING_CANCELLED=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    for c in data.get('checkins', []):
        if c.get('id') == '100':
            print(c.get('status', ''))
            break
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null)

if [[ "$PENDING_CANCELLED" == "cancelled" ]]; then
    pass "Pending checkin entry marked as cancelled"
else
    fail "Pending entry should be cancelled, got: $PENDING_CANCELLED"
fi

# Verify: cancelled_at timestamp on the cancelled entry
HAS_CANCELLED_AT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    for c in data.get('checkins', []):
        if c.get('id') == '100':
            print('yes' if c.get('cancelled_at') else 'no')
            break
except:
    print('error')
" 2>/dev/null)

if [[ "$HAS_CANCELLED_AT" == "yes" ]]; then
    pass "Cancelled entry has cancelled_at timestamp"
else
    fail "Cancelled entry should have cancelled_at timestamp"
fi

# Verify: stale-state-cleaned audit entry exists
AUDIT_ENTRY=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    cleaned = [c for c in data.get('checkins', []) if c.get('status') == 'stale-state-cleaned']
    if cleaned:
        print(f'found:{len(cleaned)}')
    else:
        print('none')
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null)

if [[ "$AUDIT_ENTRY" == "found:1" ]]; then
    pass "stale-state-cleaned audit entry added to checkins.json"
else
    fail "Expected 1 stale-state-cleaned entry, got: $AUDIT_ENTRY"
fi

# Verify: stale-state-cleaned entry has correct note
AUDIT_NOTE=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    for c in data.get('checkins', []):
        if c.get('status') == 'stale-state-cleaned':
            print(c.get('note', ''))
            break
except:
    print('error')
" 2>/dev/null)

if echo "$AUDIT_NOTE" | grep -qi "stale state cleaned"; then
    pass "Audit entry has descriptive note"
else
    fail "Audit entry note should mention stale state cleanup, got: $AUDIT_NOTE"
fi

# Verify: status.yml updated to 'completed'
STATUS_VALUE=$(uv run python -c "
import yaml
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        data = yaml.safe_load(f)
    print(data.get('status', ''))
except Exception as e:
    print(f'error: {e}')
" 2>/dev/null)

if [[ "$STATUS_VALUE" == "completed" ]]; then
    pass "status.yml updated to 'completed'"
else
    fail "status.yml should be 'completed', got: $STATUS_VALUE"
fi

# Verify: status.yml has completed_at timestamp
COMPLETED_AT=$(uv run python -c "
import yaml
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        data = yaml.safe_load(f)
    print('yes' if data.get('completed_at') else 'no')
except:
    print('error')
" 2>/dev/null)

if [[ "$COMPLETED_AT" == "yes" ]]; then
    pass "status.yml has completed_at timestamp"
else
    fail "status.yml should have completed_at timestamp"
fi

# Verify: 'done' entry unchanged (not affected by cleanup)
DONE_ENTRY_STATUS=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    for c in data.get('checkins', []):
        if c.get('id') == '99':
            print(c.get('status', ''))
            break
except:
    print('error')
" 2>/dev/null)

if [[ "$DONE_ENTRY_STATUS" == "done" ]]; then
    pass "Previously 'done' entry unchanged by cleanup"
else
    fail "Done entry should remain 'done', got: $DONE_ENTRY_STATUS"
fi

echo ""

# ============================================================
# Test 2: No cleanup when daemon_pid is already null
# ============================================================
echo "Test 2: No cleanup when daemon_pid is already null..."

# Setup: null daemon_pid, all tasks complete
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-200", "status": "stopped", "note": "Normal stop", "created_at": "2024-01-01T10:00:00"}
  ],
  "daemon_pid": null
}
EOF

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: $SESSION_NAME
EOF

# Run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'STALE_HOOK_DONE_2'"
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

# Verify: no stale-state-cleaned entry added
CLEANUP_COUNT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    cleaned = [c for c in data.get('checkins', []) if c.get('status') == 'stale-state-cleaned']
    print(len(cleaned))
except:
    print(-1)
" 2>/dev/null)

if [[ "$CLEANUP_COUNT" == "0" ]]; then
    pass "No cleanup when daemon_pid is already null"
else
    fail "Should not cleanup when daemon_pid is null, found $CLEANUP_COUNT entries"
fi

# Verify: status.yml NOT changed to completed (no stale state to clean)
STATUS_VALUE=$(uv run python -c "
import yaml
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        data = yaml.safe_load(f)
    print(data.get('status', ''))
except:
    print('error')
" 2>/dev/null)

if [[ "$STATUS_VALUE" == "in-progress" ]]; then
    pass "status.yml remains 'in-progress' (no stale state)"
else
    fail "status.yml should still be 'in-progress', got: $STATUS_VALUE"
fi

echo ""

# ============================================================
# Test 3: No cleanup when incomplete tasks exist (restart instead)
# ============================================================
echo "Test 3: Dead daemon + incomplete tasks → restart, not cleanup..."

# Setup: dead daemon + incomplete tasks
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "300", "status": "pending", "scheduled_for": "2024-01-01T12:00:00", "note": "Pending", "target": "test:0", "created_at": "2024-01-01T11:55:00"}
  ],
  "daemon_pid": 999998
}
EOF

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "developer", "status": "in_progress", "blockedBy": [], "blocks": []}
  ]
}
EOF

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: $SESSION_NAME
EOF

# Run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'STALE_HOOK_DONE_3'"
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

# Give daemon time to start
sleep 3

# Verify: no stale-state-cleaned entry (restart path taken, not cleanup)
CLEANUP_COUNT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    cleaned = [c for c in data.get('checkins', []) if c.get('status') == 'stale-state-cleaned']
    print(len(cleaned))
except:
    print(-1)
" 2>/dev/null)

if [[ "$CLEANUP_COUNT" == "0" ]]; then
    pass "No stale-state-cleaned entry (restart path taken instead)"
else
    fail "Should not have stale-state-cleaned entry when tasks are incomplete"
fi

# Verify: daemon was restarted (new PID set)
DAEMON_PID=$(uv run python -c "
import json, os
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
    else:
        print('')
except:
    print('')
" 2>/dev/null)

if [[ -n "$DAEMON_PID" ]]; then
    pass "Daemon restarted for incomplete tasks (PID: $DAEMON_PID)"
    # Kill the daemon for subsequent tests
    kill -9 "$DAEMON_PID" 2>/dev/null || true
    sleep 1
else
    fail "Daemon should have been restarted for incomplete tasks"
fi

echo ""

# ============================================================
# Test 4: Cleanup with multiple pending entries
# ============================================================
echo "Test 4: Cleanup cancels ALL pending entries..."

# Setup: dead daemon, multiple pending entries, all tasks complete
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "400", "status": "pending", "scheduled_for": "2024-01-01T12:00:00", "note": "Pending 1", "target": "test:0", "created_at": "2024-01-01T11:55:00"},
    {"id": "401", "status": "done", "completed_at": "2024-01-01T11:50:00", "note": "Completed checkin", "target": "test:0", "created_at": "2024-01-01T11:45:00"},
    {"id": "402", "status": "pending", "scheduled_for": "2024-01-01T12:05:00", "note": "Pending 2", "target": "test:0", "created_at": "2024-01-01T11:55:00"}
  ],
  "daemon_pid": 999997
}
EOF

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: $SESSION_NAME
EOF

# Run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'STALE_HOOK_DONE_4'"
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

# Verify: both pending entries cancelled
CANCELLED_COUNT=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    cancelled = [c for c in data.get('checkins', []) if c.get('status') == 'cancelled']
    print(len(cancelled))
except:
    print(-1)
" 2>/dev/null)

if [[ "$CANCELLED_COUNT" == "2" ]]; then
    pass "Both pending entries cancelled (count: $CANCELLED_COUNT)"
else
    fail "Expected 2 cancelled entries, got: $CANCELLED_COUNT"
fi

# Verify: 'done' entry still unchanged
DONE_STATUS=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    for c in data.get('checkins', []):
        if c.get('id') == '401':
            print(c.get('status', ''))
            break
except:
    print('error')
" 2>/dev/null)

if [[ "$DONE_STATUS" == "done" ]]; then
    pass "Done entry preserved during multi-pending cleanup"
else
    fail "Done entry should remain 'done', got: $DONE_STATUS"
fi

echo ""

# ============================================================
# Test 5: Cleanup preserves existing completed_at in status.yml
# ============================================================
echo "Test 5: Cleanup does not duplicate completed_at..."

# Setup: dead daemon, all tasks complete, status.yml already has completed_at
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << 'EOF'
{
  "checkins": [],
  "daemon_pid": 999996
}
EOF

cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

cat > "$TEST_DIR/.workflow/001-test/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: $SESSION_NAME
completed_at: 2024-01-01T09:00:00
EOF

# Run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'STALE_HOOK_DONE_5'"
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

# Verify: completed_at appears only once (not duplicated)
COMPLETED_AT_COUNT=$(uv run python -c "
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        content = f.read()
    count = content.count('completed_at:')
    print(count)
except:
    print(-1)
" 2>/dev/null)

if [[ "$COMPLETED_AT_COUNT" == "1" ]]; then
    pass "completed_at not duplicated in status.yml"
else
    fail "completed_at should appear once, found: $COMPLETED_AT_COUNT times"
fi

# Verify: status changed to completed
STATUS_VALUE=$(uv run python -c "
import yaml
try:
    with open('$TEST_DIR/.workflow/001-test/status.yml', 'r') as f:
        data = yaml.safe_load(f)
    print(data.get('status', ''))
except:
    print('error')
" 2>/dev/null)

if [[ "$STATUS_VALUE" == "completed" ]]; then
    pass "status.yml updated to completed even with pre-existing completed_at"
else
    fail "status.yml should be 'completed', got: $STATUS_VALUE"
fi

echo ""

# ============================================================
# Results
# ============================================================
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
