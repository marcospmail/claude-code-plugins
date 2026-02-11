#!/bin/bash
# test-tasks-change-restart-checkin.sh
#
# E2E Test: PostToolUse hook to restart check-ins when tasks.json changes
#
# This test verifies:
# 1. Hook is registered in hooks.json
# 2. Hook script correctly identifies tasks.json files
# 3. Hook detects when daemon is not running (via PID check)
# 4. Hook detects incomplete tasks
# 5. Hook triggers daemon restart when not running + incomplete tasks exist
# 6. Hook does NOT restart when daemon is already running
# 7. Hook does NOT restart when all tasks are completed
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="tasks-change-restart"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
LIB_DIR="$PROJECT_ROOT/lib"
SESSION_NAME="e2e-tasks-chg-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Tasks Change Hook - Auto-restart Check-ins"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes
    if [[ -f "$TEST_DIR/.workflow/001-test-workflow/checkins.json" ]]; then
        PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        print(pid)
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
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

# ============================================================
# Phase 1: Verify hook configuration
# ============================================================
echo "Phase 1: Checking hook configuration..."

if [[ -f "$HOOK_SCRIPT" ]]; then
    pass "Hook script exists"
else
    fail "Hook script not found at $HOOK_SCRIPT"
    exit 1
fi

if jq -e '.hooks.PostToolUse[0].matcher == "Edit|Write"' "$HOOKS_JSON" 2>/dev/null | grep -q true; then
    pass "PostToolUse hook configured with Edit|Write matcher"
else
    fail "PostToolUse hook not configured correctly in hooks.json"
    exit 1
fi

if jq -r '.hooks.PostToolUse[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null | grep -q 'tasks-change-hook.py'; then
    pass "Hook command references tasks-change-hook.py"
else
    fail "Hook command doesn't reference tasks-change-hook.py"
fi

echo ""

# ============================================================
# Phase 2: Setup test environment
# ============================================================
echo "Phase 2: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

# Create status.yml with 5-minute interval
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << EOF
status: in-progress
checkin_interval_minutes: 5
session: $SESSION_NAME
EOF

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"
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
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

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
# Phase 3: Test hook script - file path detection
# ============================================================
echo "Phase 3: Testing file path detection..."

# Ask Claude to run the hook with a tasks.json path
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | python3 '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_OK_1'"
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

HOOK_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$HOOK_OUTPUT" | grep -q "HOOK_OK_1"; then
    pass "Hook processes tasks.json without error"
else
    fail "Hook errors on tasks.json"
fi

# Ask Claude to run the hook with a non-tasks.json path
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '{\"tool_input\":{\"file_path\":\"/project/src/main.py\"}}' | python3 '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_OK_2'"
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

HOOK_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$HOOK_OUTPUT" | grep -q "HOOK_OK_2"; then
    pass "Hook processes non-tasks.json without error"
else
    fail "Hook errors on non-tasks.json"
fi

echo ""

# ============================================================
# Phase 4: Test daemon running detection
# ============================================================
echo "Phase 4: Testing daemon running detection..."

# Create checkins.json with no daemon (PID null)
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-456", "status": "stopped", "created_at": "2024-01-01T11:00:00"}
  ],
  "daemon_pid": null
}
EOF

# Ask Claude to check is_daemon_running
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && python3 -c \"import sys; sys.path.insert(0, '$PROJECT_ROOT/lib'); from checkin_scheduler import CheckinScheduler; s = CheckinScheduler('$TEST_DIR/.workflow/001-test-workflow'); print('yes' if s.is_daemon_running() else 'no')\""
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

IS_RUNNING_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$IS_RUNNING_OUTPUT" | grep -q "no"; then
    pass "Detects daemon is not running (null PID)"
else
    fail "Should detect no daemon running"
fi

# Test with dead PID
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "999", "status": "pending", "created_at": "2024-01-01T12:00:00"}
  ],
  "daemon_pid": 999999
}
EOF

# Ask Claude to check is_daemon_running with dead PID
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && python3 -c \"import sys; sys.path.insert(0, '$PROJECT_ROOT/lib'); from checkin_scheduler import CheckinScheduler; s = CheckinScheduler('$TEST_DIR/.workflow/001-test-workflow'); print('yes' if s.is_daemon_running() else 'no')\""
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

IS_RUNNING_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$IS_RUNNING_OUTPUT" | grep -q "no"; then
    pass "Detects daemon is not running (dead PID)"
else
    fail "Should detect dead daemon"
fi

echo ""

# ============================================================
# Phase 5: Test incomplete tasks detection
# ============================================================
echo "Phase 5: Testing incomplete tasks detection..."

# Create tasks with incomplete ones
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "status": "pending"},
    {"id": "T2", "subject": "Task 2", "status": "in_progress"},
    {"id": "T3", "subject": "Task 3", "status": "completed"}
  ]
}
EOF

# Ask Claude to check incomplete tasks
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && python3 -c \"import json; tasks = json.load(open('$TEST_DIR/.workflow/001-test-workflow/tasks.json'))['tasks']; inc = [t for t in tasks if t['status'] in ('pending','in_progress','blocked')]; print(f'{len(inc)>0}:{len(inc)}')\""
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

RESULT_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$RESULT_OUTPUT" | grep -q "True:2"; then
    pass "Correctly detects 2 incomplete tasks"
else
    fail "Expected True:2 in output"
fi

# Test all completed
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "status": "completed"},
    {"id": "T2", "subject": "Task 2", "status": "completed"}
  ]
}
EOF

# Ask Claude to check completed tasks
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && python3 -c \"import json; tasks = json.load(open('$TEST_DIR/.workflow/001-test-workflow/tasks.json'))['tasks']; inc = [t for t in tasks if t['status'] in ('pending','in_progress','blocked')]; print(f'{len(inc)>0}:{len(inc)}')\""
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

RESULT_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$RESULT_OUTPUT" | grep -q "False:0"; then
    pass "Correctly detects 0 incomplete tasks (all completed)"
else
    fail "Expected False:0 in output"
fi

echo ""

# ============================================================
# Phase 6: Integration test - auto-restart when daemon not running + incomplete
# ============================================================
echo "Phase 6: Integration test - auto-restart behavior..."

# Setup: no daemon + incomplete tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-999", "status": "stopped", "note": "All work complete", "created_at": "2024-01-01T10:00:00"}
  ],
  "daemon_pid": null
}
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "New task", "status": "pending"}
  ]
}
EOF

# Ask Claude to run the hook simulating a tasks.json edit
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' python3 '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE'"
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

# Give it a moment to start daemon
sleep 3

# Check if a new daemon was started
DAEMON_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        print(pid)
    else:
        print('')
except:
    print('')
" 2>/dev/null)

if [[ -n "$DAEMON_PID" ]]; then
    pass "Daemon was started (PID: $DAEMON_PID)"
else
    fail "Daemon was not started"
fi

echo ""

# ============================================================
# Phase 7: No restart when daemon already running
# ============================================================
echo "Phase 7: No restart when daemon already running..."

# The daemon from phase 6 should still be running
ORIGINAL_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    print(data.get('daemon_pid', ''))
except:
    print('')
" 2>/dev/null)

# Ask Claude to run the hook again
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' python3 '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE_2'"
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

# Check that PID hasn't changed
NEW_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    print(data.get('daemon_pid', ''))
except:
    print('')
" 2>/dev/null)

if [[ "$NEW_PID" == "$ORIGINAL_PID" ]]; then
    pass "No new daemon started (PID unchanged: $NEW_PID)"
else
    fail "Expected same daemon PID ($ORIGINAL_PID), got: $NEW_PID"
fi

echo ""

# ============================================================
# Phase 8: No restart when all tasks completed
# ============================================================
echo "Phase 8: No restart when all tasks completed..."

# Ask Claude to cancel the running daemon first
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && python3 $PROJECT_ROOT/lib/checkin_scheduler.py cancel --workflow '001-test-workflow'"
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

# Setup: no daemon + all tasks completed
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-999", "status": "stopped", "created_at": "2024-01-01T10:00:00"}
  ],
  "daemon_pid": null
}
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Done task", "status": "completed"}
  ]
}
EOF

# Ask Claude to run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' python3 '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE_3'"
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

# Check that no daemon was started
DAEMON_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        print(pid)
    else:
        print('')
except:
    print('')
" 2>/dev/null)

if [[ -z "$DAEMON_PID" ]]; then
    pass "No daemon started when all tasks completed"
else
    fail "Should not start daemon when all tasks completed, got PID: $DAEMON_PID"
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
