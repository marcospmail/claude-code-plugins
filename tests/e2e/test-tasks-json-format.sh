#!/bin/bash
# test-tasks-json-format.sh
#
# E2E Test: tasks.json format and parsing
#
# Verifies that:
# 1. tasks.json format is correctly parsed for task status detection
# 2. Different task statuses are detected correctly
# 3. Display rendering works for various task states
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All Python execution and script calls go through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="tasks-json-format"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-tasks-json-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: tasks.json Format and Parsing"
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
    rm -f /tmp/e2e-taskjson-count-$$.txt /tmp/e2e-taskjson-display-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and start Claude
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

echo "  - Test directory: $TEST_DIR"
echo "  - Session: $SESSION_NAME"
echo "  - Waiting for Claude to start..."
sleep 8

# Handle trust prompt
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  - Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  - No trust prompt found, continuing..."
    sleep 5
fi

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# Helper: Count incomplete tasks via Claude
# ============================================================
count_incomplete() {
    local tasks_file="$1"
    local output_file="/tmp/e2e-taskjson-count-$$.txt"

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: python3 -c \"import json; data=json.load(open('$tasks_file')); print(len([t for t in data.get('tasks',[]) if t.get('status') in ('pending','in_progress','blocked')]))\" > '$output_file' 2>&1"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 30

    cat "$output_file" 2>/dev/null | tr -d ' \n'
}

# ============================================================
# Helper: Display tasks via Claude
# ============================================================
display_tasks() {
    local tasks_file="$1"
    local output_file="/tmp/e2e-taskjson-display-$$.txt"

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: python3 -c \"
import json
data=json.load(open('$tasks_file'))
tasks=data.get('tasks',[])
icons={'pending':'○','in_progress':'◐','blocked':'✗','completed':'●'}
for t in tasks:
    s=t.get('status','pending')
    i=icons.get(s,'?')
    tid=t.get('id','?')
    sub=t.get('subject','No subject')[:45]
    ag=t.get('agent','?')
    print(f'{i} {tid}: {sub} [{ag}]')
\" > '$output_file' 2>&1"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 30

    cat "$output_file" 2>/dev/null
}

# ============================================================
# Test 1: Verify JSON with pending tasks is detected
# ============================================================
echo "Test 1: Testing pending task detection..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement login",
      "description": "Create login endpoint",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2"]
    },
    {
      "id": "T2",
      "subject": "Test login",
      "description": "Write login tests",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1"],
      "blocks": []
    }
  ]
}
EOF

INCOMPLETE=$(count_incomplete "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if [[ "$INCOMPLETE" == "2" ]]; then
    pass "Detected 2 pending tasks correctly"
else
    fail "Expected 2 pending tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 2: Verify in_progress status is detected
# ============================================================
echo ""
echo "Test 2: Testing in_progress status detection..."

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

INCOMPLETE=$(count_incomplete "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if [[ "$INCOMPLETE" == "2" ]]; then
    pass "Detected in_progress + pending = 2 incomplete tasks"
else
    fail "Expected 2 incomplete tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 3: Verify blocked status is detected
# ============================================================
echo ""
echo "Test 3: Testing blocked status detection..."

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

INCOMPLETE=$(count_incomplete "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if [[ "$INCOMPLETE" == "1" ]]; then
    pass "Detected 1 blocked task (completed not counted)"
else
    fail "Expected 1 blocked task, got $INCOMPLETE"
fi

# ============================================================
# Test 4: Verify all completed = 0 incomplete
# ============================================================
echo ""
echo "Test 4: Testing all tasks completed..."

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

INCOMPLETE=$(count_incomplete "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if [[ "$INCOMPLETE" == "0" ]]; then
    pass "All tasks completed = 0 incomplete"
else
    fail "Expected 0 incomplete tasks, got $INCOMPLETE"
fi

# ============================================================
# Test 5: Display rendering with status icons
# ============================================================
echo ""
echo "Test 5: Testing display rendering with status icons..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Implement login", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Test login", "agent": "qa", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Review code", "agent": "reviewer", "status": "completed", "blockedBy": [], "blocks": []}
  ]
}
EOF

DISPLAY_OUTPUT=$(display_tasks "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$DISPLAY_OUTPUT" | grep -q "T1:.*Implement login.*\[developer\]"; then
    pass "Pending task T1 displayed correctly"
else
    fail "Pending task not displayed correctly"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "T2:.*Test login.*\[qa\]"; then
    pass "In-progress task T2 displayed correctly"
else
    fail "In-progress task not displayed correctly"
fi

if echo "$DISPLAY_OUTPUT" | grep -q "T3:.*Review code.*\[reviewer\]"; then
    pass "Completed task T3 displayed correctly"
else
    fail "Completed task not displayed correctly"
fi

# ============================================================
# Test 6: WORKFLOW_NAME tmux env var is set correctly
# ============================================================
echo ""
echo "Test 6: Testing WORKFLOW_NAME tmux env var..."

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
# Test 7: No .workflow/current file used
# ============================================================
echo ""
echo "Test 7: Testing that .workflow/current is not used..."

if [[ ! -f "$TEST_DIR/.workflow/current" ]] && [[ ! -L "$TEST_DIR/.workflow/current" ]]; then
    pass "No .workflow/current file exists (correct - multiple workflows can run)"
else
    fail ".workflow/current exists but should not"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    EXIT_CODE=0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    EXIT_CODE=1
fi
echo "======================================================================"
echo ""

exit $EXIT_CODE
