#!/bin/bash
# test-tasks-change-restart-checkin.sh
#
# E2E Test: PostToolUse hook to restart check-ins when tasks.json changes
#
# This test verifies:
# 1. Hook is registered in hooks.json
# 2. Hook script correctly identifies tasks.json files
# 3. Hook detects when check-in loop is stopped
# 4. Hook detects incomplete tasks
# 5. Hook triggers check-in restart when stopped + incomplete tasks exist
# 6. Hook does NOT restart when check-in is already running
# 7. Hook does NOT restart when all tasks are completed

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="tasks-change-restart"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    pkill -f "schedule-checkin.*$TEST_DIR" 2>/dev/null || true
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
# Phase 4: Test check-in stopped detection
# ============================================================
echo "Phase 4: Testing check-in stopped detection..."

# Create checkins.json with stopped state
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "123", "status": "done", "created_at": "2024-01-01T10:00:00"},
    {"id": "stop-456", "status": "stopped", "created_at": "2024-01-01T11:00:00"}
  ]
}
EOF

IS_STOPPED=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT')
exec(open('$HOOK_SCRIPT').read().replace('if __name__', 'if False'))

from pathlib import Path
workflow_path = Path('$TEST_DIR/.workflow/001-test-workflow')
result = is_checkin_stopped(workflow_path)
print('yes' if result else 'no')
" 2>/dev/null)

if [[ "$IS_STOPPED" == "yes" ]]; then
    pass "Detects check-in loop is stopped"
else
    fail "Should detect stopped check-in, got: $IS_STOPPED"
fi

# Test resumed state
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-456", "status": "stopped", "created_at": "2024-01-01T11:00:00"},
    {"id": "resume-789", "status": "resumed", "created_at": "2024-01-01T12:00:00"},
    {"id": "999", "status": "pending", "created_at": "2024-01-01T12:00:00"}
  ]
}
EOF

IS_STOPPED=$(python3 -c "
import sys
sys.path.insert(0, '$PROJECT_ROOT')
exec(open('$HOOK_SCRIPT').read().replace('if __name__', 'if False'))

from pathlib import Path
workflow_path = Path('$TEST_DIR/.workflow/001-test-workflow')
result = is_checkin_stopped(workflow_path)
print('yes' if result else 'no')
" 2>/dev/null)

if [[ "$IS_STOPPED" == "no" ]]; then
    pass "Detects check-in loop is running (has pending)"
else
    fail "Should detect running check-in, got: $IS_STOPPED"
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
# Phase 6: Integration test - auto-restart when stopped + incomplete
# ============================================================
echo "Phase 6: Integration test - auto-restart behavior..."

# Setup: stopped check-in + incomplete tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-999", "status": "stopped", "note": "All work complete", "created_at": "2024-01-01T10:00:00"}
  ]
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

# Give it a moment to schedule
sleep 2

# Check if a new check-in was scheduled
CHECKIN_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$CHECKIN_COUNT" -ge "1" ]]; then
    pass "Check-in was restarted (pending check-in found)"
else
    # Check if resumed entry was added
    RESUMED=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    resumed = [c for c in data['checkins'] if c.get('status') == 'resumed']
    print(len(resumed))
except:
    print(0)
" 2>/dev/null)
    if [[ "$RESUMED" -ge "1" ]]; then
        pass "Check-in loop was resumed (resumed entry found)"
    else
        fail "Check-in was not restarted (pending: $CHECKIN_COUNT, resumed: $RESUMED)"
        echo "  Hook output: $HOOK_OUTPUT"
        echo "  Checkins file:"
        cat "$TEST_DIR/.workflow/001-test-workflow/checkins.json"
    fi
fi

echo ""

# ============================================================
# Phase 7: No restart when check-in already running
# ============================================================
echo "Phase 7: No restart when check-in already running..."

# Setup: running check-in (has pending)
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "existing-123", "status": "pending", "created_at": "2024-01-01T10:00:00"}
  ]
}
EOF

# Run the hook
HOOK_INPUT="{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}"
cd "$TEST_DIR"
echo "$HOOK_INPUT" | YATO_PATH="$PROJECT_ROOT" python3 "$HOOK_SCRIPT" 2>&1

sleep 1

# Count pending check-ins (should still be 1, not 2)
CHECKIN_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$CHECKIN_COUNT" == "1" ]]; then
    pass "No duplicate check-in scheduled (count remains 1)"
else
    fail "Expected 1 pending check-in, got: $CHECKIN_COUNT"
fi

echo ""

# ============================================================
# Phase 8: No restart when all tasks completed
# ============================================================
echo "Phase 8: No restart when all tasks completed..."

# Setup: stopped + all tasks completed
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-999", "status": "stopped", "created_at": "2024-01-01T10:00:00"}
  ]
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

# Count pending check-ins (should be 0)
CHECKIN_COUNT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$CHECKIN_COUNT" == "0" ]]; then
    pass "No check-in scheduled when all tasks completed"
else
    fail "Should not restart when all tasks completed, got pending: $CHECKIN_COUNT"
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
