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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="tasks-change-restart"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
LIB_DIR="$PROJECT_ROOT/lib"
SESSION_NAME="e2e-tasks-chg-$TEST_ID"

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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
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

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"
tmux setenv -t "$SESSION_NAME" YATO_PATH "$PROJECT_ROOT"

if tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    pass "Tmux session created"
else
    fail "Failed to create tmux session"
    exit 1
fi

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Phase 3: Test hook script - file path detection
# ============================================================
echo "Phase 3: Testing file path detection..."

# Test tasks.json path triggers processing
TASKS_INPUT="{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}"
# Just check that script runs without error for tasks.json
if echo "$TASKS_INPUT" | python3 "$HOOK_SCRIPT" 2>&1; then
    pass "Hook processes tasks.json without error"
else
    fail "Hook errors on tasks.json"
fi

# Test non-tasks.json path
OTHER_INPUT='{"tool_input":{"file_path":"/project/src/main.py"}}'
if echo "$OTHER_INPUT" | python3 "$HOOK_SCRIPT" 2>&1; then
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

IS_RUNNING=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT/lib')
from checkin_scheduler import CheckinScheduler

scheduler = CheckinScheduler('$TEST_DIR/.workflow/001-test-workflow')
result = scheduler.is_daemon_running()
print('yes' if result else 'no')
" 2>/dev/null)

if [[ "$IS_RUNNING" == "no" ]]; then
    pass "Detects daemon is not running (null PID)"
else
    fail "Should detect no daemon running, got: $IS_RUNNING"
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

IS_RUNNING=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT/lib')
from checkin_scheduler import CheckinScheduler

scheduler = CheckinScheduler('$TEST_DIR/.workflow/001-test-workflow')
result = scheduler.is_daemon_running()
print('yes' if result else 'no')
" 2>/dev/null)

if [[ "$IS_RUNNING" == "no" ]]; then
    pass "Detects daemon is not running (dead PID)"
else
    fail "Should detect dead daemon, got: $IS_RUNNING"
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

RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT')
exec(open('$HOOK_SCRIPT').read().replace('if __name__', 'if False'))

from pathlib import Path
workflow_path = Path('$TEST_DIR/.workflow/001-test-workflow')
has_inc, count = has_incomplete_tasks(workflow_path)
print(f'{has_inc}:{count}')
" 2>/dev/null)

if [[ "$RESULT" == "True:2" ]]; then
    pass "Correctly detects 2 incomplete tasks"
else
    fail "Expected True:2, got: $RESULT"
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

RESULT=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT')
exec(open('$HOOK_SCRIPT').read().replace('if __name__', 'if False'))

from pathlib import Path
workflow_path = Path('$TEST_DIR/.workflow/001-test-workflow')
has_inc, count = has_incomplete_tasks(workflow_path)
print(f'{has_inc}:{count}')
" 2>/dev/null)

if [[ "$RESULT" == "False:0" ]]; then
    pass "Correctly detects 0 incomplete tasks (all completed)"
else
    fail "Expected False:0, got: $RESULT"
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

# Run the hook simulating a tasks.json edit
HOOK_INPUT="{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}"
cd "$TEST_DIR"
HOOK_OUTPUT=$(echo "$HOOK_INPUT" | YATO_PATH="$PROJECT_ROOT" python3 "$HOOK_SCRIPT" 2>&1)

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
    echo "  Hook output: $HOOK_OUTPUT"
fi

echo ""

# ============================================================
# Phase 7: No restart when daemon already running
# ============================================================
echo "Phase 7: No restart when daemon already running..."

# The daemon from phase 6 should still be running
# Record the current PID
ORIGINAL_PID=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    print(data.get('daemon_pid', ''))
except:
    print('')
" 2>/dev/null)

# Run the hook again
HOOK_INPUT="{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}"
cd "$TEST_DIR"
echo "$HOOK_INPUT" | YATO_PATH="$PROJECT_ROOT" python3 "$HOOK_SCRIPT" 2>&1

sleep 1

# Check that PID hasn't changed (no new daemon started)
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

# Kill the running daemon first
cd "$TEST_DIR" && python3 "$LIB_DIR/checkin_scheduler.py" cancel --workflow "001-test-workflow" > /dev/null 2>&1
sleep 1

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

# Run the hook
HOOK_INPUT="{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}"
cd "$TEST_DIR"
echo "$HOOK_INPUT" | YATO_PATH="$PROJECT_ROOT" python3 "$HOOK_SCRIPT" 2>&1

sleep 1

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
