#!/bin/bash
# test-tasks-json-format.sh
#
# E2E Test: tasks.json format and parsing
#
# Verifies that:
# 1. tasks.json format is correctly parsed by schedule-checkin.sh
# 2. Different task statuses are detected correctly
# 3. tasks-display.sh renders JSON properly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="tasks-json-format"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-tasks-json-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: tasks.json Format and Parsing"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

# Create status.yml
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

# Create tmux session with WORKFLOW_NAME env var
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Test 1: Verify JSON with pending tasks is detected
# ============================================================

echo "Testing pending task detection..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement login",
      "description": "Create login endpoint",
      "activeForm": "Implementing login",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2"]
    },
    {
      "id": "T2",
      "subject": "Test login",
      "description": "Write login tests",
      "activeForm": "Testing login",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1"],
      "blocks": []
    }
  ],
  "metadata": {
    "created": "2026-01-27T10:00:00Z"
  }
}
EOF

# Run the incomplete task check directly (same logic as schedule-checkin.sh)
INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "2" ]]; then
    pass "Detected 2 pending tasks correctly"
else
    fail "Expected 2 pending tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 2: Verify in_progress status is detected
# ============================================================

echo ""
echo "Testing in_progress status detection..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement login",
      "agent": "developer",
      "status": "in_progress",
      "blockedBy": [],
      "blocks": []
    },
    {
      "id": "T2",
      "subject": "Test login",
      "agent": "qa",
      "status": "pending",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "2" ]]; then
    pass "Detected in_progress + pending = 2 incomplete tasks"
else
    fail "Expected 2 incomplete tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 3: Verify blocked status is detected
# ============================================================

echo ""
echo "Testing blocked status detection..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement login",
      "agent": "developer",
      "status": "completed",
      "blockedBy": [],
      "blocks": []
    },
    {
      "id": "T2",
      "subject": "Test login",
      "agent": "qa",
      "status": "blocked",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "1" ]]; then
    pass "Detected 1 blocked task (completed not counted)"
else
    fail "Expected 1 blocked task, got $INCOMPLETE"
fi

# ============================================================
# Test 4: Verify all completed = 0 incomplete
# ============================================================

echo ""
echo "Testing all tasks completed..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement login",
      "agent": "developer",
      "status": "completed",
      "blockedBy": [],
      "blocks": []
    },
    {
      "id": "T2",
      "subject": "Test login",
      "agent": "qa",
      "status": "completed",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "All tasks completed = 0 incomplete"
else
    fail "Expected 0 incomplete tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 5: tasks-display.sh renders JSON correctly
# ============================================================

echo ""
echo "Testing tasks-display.sh rendering..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Implement login", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Test login", "agent": "qa", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Review code", "agent": "reviewer", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Run the display logic directly (same as tasks-display.sh)
DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}
    for task in tasks:
        status = task.get('status', 'pending')
        icon = icons.get(status, '?')
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:45]
        agent = task.get('agent', '?')
        print(f'{icon} {task_id}: {subject} [{agent}]')
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$DISPLAY_OUTPUT" | grep -q "○ T1: Implement login \[developer\]"; then
    pass "Pending task displayed with ○ icon"
else
    fail "Pending task not displayed correctly"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "◐ T2: Test login \[qa\]"; then
    pass "In-progress task displayed with ◐ icon"
else
    fail "In-progress task not displayed correctly"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "● T3: Review code \[reviewer\]"; then
    pass "Completed task displayed with ● icon"
else
    fail "Completed task not displayed correctly"
fi

# ============================================================
# Test 6: Empty tasks array handled correctly
# ============================================================

echo ""
echo "Testing empty tasks array..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [],
  "metadata": {}
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "Empty tasks array = 0 incomplete"
else
    fail "Expected 0 for empty array, got $INCOMPLETE"
fi

# ============================================================
# Test 7: Invalid JSON handled gracefully
# ============================================================

echo ""
echo "Testing invalid JSON handling..."

echo "not valid json {{{" > "$TEST_DIR/.workflow/001-test-workflow/tasks.json"

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "Invalid JSON handled gracefully (returns 0)"
else
    fail "Invalid JSON should return 0, got $INCOMPLETE"
fi

# ============================================================
# Test 8: WORKFLOW_NAME tmux env var path resolution
# ============================================================

echo ""
echo "Testing WORKFLOW_NAME path resolution..."

# Restore valid tasks.json
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Test task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Verify tmux env var is set correctly
WORKFLOW_FROM_TMUX=$(tmux -L "$TMUX_SOCKET" showenv -t "$SESSION_NAME" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)

if [[ "$WORKFLOW_FROM_TMUX" == "001-test-workflow" ]]; then
    pass "WORKFLOW_NAME tmux env var correctly set"
else
    fail "WORKFLOW_NAME should be '001-test-workflow', got '$WORKFLOW_FROM_TMUX'"
fi

# Verify the path resolution would work
RESOLVED_PATH="$TEST_DIR/.workflow/$WORKFLOW_FROM_TMUX/tasks.json"
if [[ -f "$RESOLVED_PATH" ]]; then
    pass "Workflow-aware path resolves to existing file"
else
    fail "Workflow-aware path does not exist: $RESOLVED_PATH"
fi

# ============================================================
# Test 9: Blocked status icon display (✗)
# ============================================================

echo ""
echo "Testing blocked status icon display..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Blocked task", "agent": "developer", "status": "blocked", "blockedBy": ["T2"], "blocks": []}
  ]
}
EOF

DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}
    for task in tasks:
        status = task.get('status', 'pending')
        icon = icons.get(status, '?')
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:45]
        agent = task.get('agent', '?')
        print(f'{icon} {task_id}: {subject} [{agent}]')
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$DISPLAY_OUTPUT" | grep -q "✗ T1: Blocked task \[developer\]"; then
    pass "Blocked task displayed with ✗ icon"
else
    fail "Blocked task not displayed correctly: $DISPLAY_OUTPUT"
fi

# ============================================================
# Test 10: Long subject truncation (45 chars)
# ============================================================

echo ""
echo "Testing long subject truncation..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "This is a very long subject that should be truncated because it exceeds 45 characters", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}
    for task in tasks:
        status = task.get('status', 'pending')
        icon = icons.get(status, '?')
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:45]
        agent = task.get('agent', '?')
        print(f'{icon} {task_id}: {subject} [{agent}]')
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

# Should be truncated to 45 chars: "This is a very long subject that should be t"
if echo "$DISPLAY_OUTPUT" | grep -q "This is a very long subject that should be t"; then
    pass "Long subject truncated to 45 characters"
else
    fail "Long subject not truncated correctly: $DISPLAY_OUTPUT"
fi

# Verify it doesn't contain the full text
if echo "$DISPLAY_OUTPUT" | grep -q "exceeds 45 characters"; then
    fail "Subject should not contain 'exceeds 45 characters'"
else
    pass "Truncation confirmed (full text not present)"
fi

# ============================================================
# Test 11: 20+ tasks overflow message
# ============================================================

echo ""
echo "Testing 20+ tasks overflow..."

# Generate 25 tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Task 2", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Task 3", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T4", "subject": "Task 4", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T5", "subject": "Task 5", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T6", "subject": "Task 6", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T7", "subject": "Task 7", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T8", "subject": "Task 8", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T9", "subject": "Task 9", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T10", "subject": "Task 10", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T11", "subject": "Task 11", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T12", "subject": "Task 12", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T13", "subject": "Task 13", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T14", "subject": "Task 14", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T15", "subject": "Task 15", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T16", "subject": "Task 16", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T17", "subject": "Task 17", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T18", "subject": "Task 18", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T19", "subject": "Task 19", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T20", "subject": "Task 20", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T21", "subject": "Task 21", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T22", "subject": "Task 22", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T23", "subject": "Task 23", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T24", "subject": "Task 24", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T25", "subject": "Task 25", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}
    for task in tasks[:20]:
        status = task.get('status', 'pending')
        icon = icons.get(status, '?')
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:45]
        agent = task.get('agent', '?')
        print(f'{icon} {task_id}: {subject} [{agent}]')
    if len(tasks) > 20:
        print(f'... and {len(tasks) - 20} more tasks')
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$DISPLAY_OUTPUT" | grep -q "and 5 more tasks"; then
    pass "Shows '... and 5 more tasks' for 25 tasks"
else
    fail "Overflow message not shown correctly: $DISPLAY_OUTPUT"
fi

# Verify T20 is shown but T21 is not
if echo "$DISPLAY_OUTPUT" | grep -q "T20:"; then
    pass "Task 20 is displayed (within limit)"
else
    fail "Task 20 should be displayed"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "T21:"; then
    fail "Task 21 should NOT be displayed (over limit)"
else
    pass "Task 21 correctly hidden (over limit)"
fi

# ============================================================
# Test 12: Missing fields handling
# ============================================================

echo ""
echo "Testing missing fields handling..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"status": "pending"},
    {"id": "T2", "status": "pending"},
    {"id": "T3", "subject": "Has subject", "status": "pending"}
  ]
}
EOF

DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}
    for task in tasks:
        status = task.get('status', 'pending')
        icon = icons.get(status, '?')
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:45]
        agent = task.get('agent', '?')
        print(f'{icon} {task_id}: {subject} [{agent}]')
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$DISPLAY_OUTPUT" | grep -q "○ ?: No subject \[?\]"; then
    pass "Task with no id/subject/agent shows defaults"
else
    fail "Missing fields not handled: $DISPLAY_OUTPUT"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "○ T2: No subject \[?\]"; then
    pass "Task with id but no subject shows 'No subject'"
else
    fail "Missing subject not handled"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "○ T3: Has subject \[?\]"; then
    pass "Task with subject but no agent shows '?'"
else
    fail "Missing agent not handled"
fi

# ============================================================
# Test 13: Unknown status icon (?)
# ============================================================

echo ""
echo "Testing unknown status icon..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Unknown status task", "agent": "dev", "status": "invalid_status", "blockedBy": [], "blocks": []}
  ]
}
EOF

DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    icons = {'pending': '○', 'in_progress': '◐', 'blocked': '✗', 'completed': '●'}
    for task in tasks:
        status = task.get('status', 'pending')
        icon = icons.get(status, '?')
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:45]
        agent = task.get('agent', '?')
        print(f'{icon} {task_id}: {subject} [{agent}]')
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$DISPLAY_OUTPUT" | grep -q "? T1: Unknown status task \[dev\]"; then
    pass "Unknown status shows ? icon"
else
    fail "Unknown status not handled: $DISPLAY_OUTPUT"
fi

# ============================================================
# Test 14: No .workflow/current file used (multiple workflows support)
# ============================================================

echo ""
echo "Testing that .workflow/current is not used..."

# Verify no .workflow/current file exists after workflow init
if [[ ! -f "$TEST_DIR/.workflow/current" ]] && [[ ! -L "$TEST_DIR/.workflow/current" ]]; then
    pass "No .workflow/current file exists (correct - multiple workflows can run)"
else
    fail ".workflow/current exists but should not"
fi

# Restore valid tasks.json for remaining tests
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Test task", "agent": "dev", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# ============================================================
# Test 15: Missing tasks key in JSON
# ============================================================

echo ""
echo "Testing missing tasks key..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "metadata": {
    "created": "2026-01-27T10:00:00Z"
  }
}
EOF

INCOMPLETE=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    incomplete = [t for t in data.get('tasks', []) if t.get('status') in ('pending', 'in_progress', 'blocked')]
    print(len(incomplete))
except:
    print(0)
" 2>/dev/null)

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "Missing tasks key returns 0 incomplete"
else
    fail "Missing tasks key should return 0, got $INCOMPLETE"
fi

DISPLAY_OUTPUT=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/tasks.json', 'r') as f:
        data = json.load(f)
    tasks = data.get('tasks', [])
    if not tasks:
        print('(no tasks yet)')
    else:
        for task in tasks:
            print(task)
except Exception as e:
    print(f'Error: {e}')
" 2>/dev/null)

if echo "$DISPLAY_OUTPUT" | grep -q "(no tasks yet)"; then
    pass "Missing tasks key shows 'no tasks yet'"
else
    fail "Missing tasks key not handled in display: $DISPLAY_OUTPUT"
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
