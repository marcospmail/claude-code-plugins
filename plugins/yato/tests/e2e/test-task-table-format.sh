#!/bin/bash
# test-task-table-format.sh
#
# E2E Test: Task Proposal Table Format
#
# Verifies that task proposals always use the table format:
# | ID | Task | Agent | Status |
#
# Status shows: "pending", "in_progress", "blocked by TX", etc.
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All script execution goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="task-table-format"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-table-format-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Task Proposal Table Format"
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
    rm -f /tmp/e2e-table-output-$$.txt /tmp/e2e-table-script-$$.py /tmp/e2e-tasktable-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow
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
# Helper: Generate table via Claude
# ============================================================

# Create the table generator Python script once
cat > /tmp/e2e-table-script-$$.py << 'PYEOF'
import json
import sys

tasks_file = sys.argv[1]
try:
    with open(tasks_file, 'r') as f:
        data = json.load(f)

    tasks = data.get('tasks', [])
    if not tasks:
        print("(no tasks)")
        sys.exit(0)

    # Print table header
    print("| ID | Task | Agent | Status |")
    print("|----|------|-------|--------|")

    for task in tasks:
        task_id = task.get('id', '?')
        subject = task.get('subject', 'No subject')[:40]
        agent = task.get('agent', '?')
        status = task.get('status', 'pending')
        blocked_by = task.get('blockedBy', [])

        # Format status column
        if status == 'blocked' or (status == 'pending' and blocked_by):
            if blocked_by:
                status_display = f"blocked by {', '.join(blocked_by)}"
            else:
                status_display = "blocked"
        else:
            status_display = status

        print(f"| {task_id} | {subject} | {agent} | {status_display} |")

except Exception as e:
    print(f"Error: {e}")
PYEOF

generate_table() {
    local tasks_file="$1"
    local output_file="/tmp/e2e-table-output-$$.txt"

    # Ask Claude to run the table generator
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: uv run python /tmp/e2e-table-script-$$.py '$tasks_file' > '$output_file' 2>&1"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 30

    cat "$output_file" 2>/dev/null
}

# ============================================================
# Test 1: Basic table format with header
# ============================================================
echo "Test 1: Testing basic table format with header..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement user authentication",
      "description": "Create auth module",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2"]
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

# Check for header row
if echo "$TABLE_OUTPUT" | grep -q "| ID | Task | Agent | Status |"; then
    pass "Table has correct header row"
else
    fail "Missing or incorrect header row"
fi

# Check for separator row
if echo "$TABLE_OUTPUT" | grep -q "|----|------|-------|--------|"; then
    pass "Table has separator row"
else
    fail "Missing separator row"
fi

# Check for data row
if echo "$TABLE_OUTPUT" | grep -q "| T1 |"; then
    pass "Table has data row with ID"
else
    fail "Missing data row"
fi

# ============================================================
# Test 2: Status shows "blocked by T1" format
# ============================================================
echo ""
echo "Test 2: Testing blocked status format..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement login",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2"]
    },
    {
      "id": "T2",
      "subject": "Test login",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1"],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep -q "blocked by T1"; then
    pass "Status shows 'blocked by T1' format"
else
    fail "Expected 'blocked by T1' in status: $TABLE_OUTPUT"
fi

# ============================================================
# Test 3: Multiple blockers format
# ============================================================
echo ""
echo "Test 3: Testing multiple blockers format..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Setup project",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T3"]
    },
    {
      "id": "T2",
      "subject": "Create database",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T3"]
    },
    {
      "id": "T3",
      "subject": "Integration tests",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1", "T2"],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep -q "blocked by T1, T2"; then
    pass "Status shows 'blocked by T1, T2' format"
else
    fail "Expected 'blocked by T1, T2' in status: $TABLE_OUTPUT"
fi

# ============================================================
# Test 4: Different status values
# ============================================================
echo ""
echo "Test 4: Testing different status values..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Task pending",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": []
    },
    {
      "id": "T2",
      "subject": "Task in progress",
      "agent": "developer",
      "status": "in_progress",
      "blockedBy": [],
      "blocks": []
    },
    {
      "id": "T3",
      "subject": "Task completed",
      "agent": "qa",
      "status": "completed",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep "| T1 |" | grep -q "| pending |"; then
    pass "Pending status displayed correctly"
else
    fail "Pending status not correct"
fi

if echo "$TABLE_OUTPUT" | grep "| T2 |" | grep -q "| in_progress |"; then
    pass "In_progress status displayed correctly"
else
    fail "In_progress status not correct"
fi

if echo "$TABLE_OUTPUT" | grep "| T3 |" | grep -q "| completed |"; then
    pass "Completed status displayed correctly"
else
    fail "Completed status not correct"
fi

# ============================================================
# Test 5: Table has exactly 4 columns
# ============================================================
echo ""
echo "Test 5: Testing table has exactly 4 columns..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Test task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

# Count pipe characters in header row (should be 5 for 4 columns: |col1|col2|col3|col4|)
PIPE_COUNT=$(echo "$TABLE_OUTPUT" | grep "| ID |" | tr -cd '|' | wc -c | tr -d ' ')

if [[ "$PIPE_COUNT" == "5" ]]; then
    pass "Table has exactly 4 columns (5 pipe characters)"
else
    fail "Expected 5 pipe chars for 4 columns, got $PIPE_COUNT"
fi

# ============================================================
# Test 6: Task subject truncation in table
# ============================================================
echo ""
echo "Test 6: Testing task subject truncation..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "This is a very long task subject that should be truncated because it is too long for the table",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

# Subject should be truncated to 40 chars: "This is a very long task subject that sh"
if echo "$TABLE_OUTPUT" | grep -q "This is a very long task subject that sh"; then
    pass "Long subject truncated to 40 characters"
else
    fail "Subject not truncated correctly"
fi

# Should not contain the full text
if echo "$TABLE_OUTPUT" | grep -q "is too long for the table"; then
    fail "Subject should be truncated, but full text is present"
else
    pass "Truncation confirmed (full text not present)"
fi

# ============================================================
# Test 7: Empty tasks array shows "(no tasks)"
# ============================================================
echo ""
echo "Test 7: Testing empty tasks array..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": []
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep -q "(no tasks)"; then
    pass "Empty tasks shows '(no tasks)' message"
else
    fail "Expected '(no tasks)' for empty array: $TABLE_OUTPUT"
fi

# ============================================================
# Test 8: task_manager.py table produces correct format
# ============================================================
echo ""
echo "Test 8: Testing task_manager.py table through Claude..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Setup project", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Implement feature", "agent": "developer", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Write tests", "agent": "qa", "status": "pending", "blockedBy": ["T2"], "blocks": []}
  ]
}
EOF

# Run the task_manager.py table command through Claude (replaced tasks-table.sh)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/task_manager.py table --project '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

# Verify header
if echo "$SCRIPT_OUTPUT" | grep -q "| ID | Task | Agent | Status |"; then
    pass "task_manager.py table produces correct header"
else
    fail "task_manager.py table missing header: $SCRIPT_OUTPUT"
fi

# Verify data rows
if echo "$SCRIPT_OUTPUT" | grep -q "| T1 | Setup project | developer | completed |"; then
    pass "task_manager.py table shows completed task correctly"
else
    fail "task_manager.py table completed task incorrect"
fi

if echo "$SCRIPT_OUTPUT" | grep -q "blocked by T2"; then
    pass "task_manager.py table shows blocked by format"
else
    fail "task_manager.py table blocked by format incorrect"
fi

# ============================================================
# Test 9: task_manager.py table with missing file
# ============================================================
echo ""
echo "Test 9: Testing task_manager.py table with missing tasks file..."

rm -f "$TEST_DIR/.workflow/001-test-workflow/tasks.json"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/task_manager.py table --project '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

if echo "$SCRIPT_OUTPUT" | grep -q "no tasks file found"; then
    pass "task_manager.py table handles missing file gracefully"
else
    fail "task_manager.py table should report missing file: $SCRIPT_OUTPUT"
fi

# ============================================================
# Test 10: task_manager.py table with empty tasks array
# ============================================================
echo ""
echo "Test 10: Testing task_manager.py table with empty tasks array..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": []
}
EOF

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/task_manager.py table --project '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

if echo "$SCRIPT_OUTPUT" | grep -q "(no tasks)"; then
    pass "task_manager.py table shows '(no tasks)' for empty array"
else
    fail "task_manager.py table should show '(no tasks)': $SCRIPT_OUTPUT"
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
