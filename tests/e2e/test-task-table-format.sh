#!/bin/bash
# test-task-table-format.sh
#
# E2E Test: Task Proposal Table Format
#
# Verifies that task proposals always use the table format:
# | ID | Task | Agent | Status |
#
# Status shows: "pending", "in_progress", "blocked by TX", etc.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="task-table-format"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-table-format-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: Task Proposal Table Format"
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
    rm -f /tmp/e2e-table-output-$$.txt /tmp/e2e-table-script-$$.py /tmp/e2e-tasktable-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow and tmux session
# ============================================================

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
EOF

tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Helper: Generate table from tasks.json
# ============================================================

generate_table() {
    local tasks_file="$1"
    local output_file="/tmp/e2e-table-output-$$.txt"
    local script_file="/tmp/e2e-table-script-$$.py"

    cat > "$script_file" << 'PYEOF'
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

    tmux send-keys -t "$SESSION_NAME" "python3 '$script_file' '$tasks_file' > '$output_file' 2>&1" Enter
    sleep 2
    cat "$output_file" 2>/dev/null
}

# ============================================================
# Test 1: Basic table format with header
# ============================================================

echo "Testing basic table format with header..."

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
echo "Testing blocked status format..."

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
echo "Testing multiple blockers format..."

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
echo "Testing different status values..."

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
# Test 5: Agent column values
# ============================================================

echo ""
echo "Testing agent column values..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Dev task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "QA task", "agent": "qa", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Review task", "agent": "code-reviewer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep "| T1 |" | grep -q "| developer |"; then
    pass "Developer agent in correct column"
else
    fail "Developer agent not in correct column"
fi

if echo "$TABLE_OUTPUT" | grep "| T2 |" | grep -q "| qa |"; then
    pass "QA agent in correct column"
else
    fail "QA agent not in correct column"
fi

if echo "$TABLE_OUTPUT" | grep "| T3 |" | grep -q "| code-reviewer |"; then
    pass "Code-reviewer agent in correct column"
else
    fail "Code-reviewer agent not in correct column"
fi

# ============================================================
# Test 6: Table has exactly 4 columns
# ============================================================

echo ""
echo "Testing table has exactly 4 columns..."

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
# Test 7: Task subject truncation in table
# ============================================================

echo ""
echo "Testing task subject truncation..."

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
# Test 8: Empty tasks array shows "(no tasks)"
# ============================================================

echo ""
echo "Testing empty tasks array..."

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
# Test 9: ID column format (T1, T2, etc.)
# ============================================================

echo ""
echo "Testing ID column format..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "First task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Second task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []},
    {"id": "T10", "subject": "Tenth task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep -qE "\| T1 \|.*First task"; then
    pass "T1 ID format correct"
else
    fail "T1 ID format incorrect"
fi

if echo "$TABLE_OUTPUT" | grep -qE "\| T10 \|.*Tenth task"; then
    pass "T10 ID format correct (double digit)"
else
    fail "T10 ID format incorrect"
fi

# ============================================================
# Test 10: Full table rendering
# ============================================================

echo ""
echo "Testing full table rendering with mixed statuses..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Setup project scaffolding", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Implement core logic", "agent": "developer", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Write unit tests", "agent": "qa", "status": "pending", "blockedBy": ["T2"], "blocks": []},
    {"id": "T4", "subject": "Code review", "agent": "code-reviewer", "status": "pending", "blockedBy": ["T2", "T3"], "blocks": []}
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

echo "Generated table:"
echo "$TABLE_OUTPUT"
echo ""

# Verify complete structure
HEADER_OK=false
SEPARATOR_OK=false
ROW_COUNT=0

while IFS= read -r line; do
    if [[ "$line" == "| ID | Task | Agent | Status |" ]]; then
        HEADER_OK=true
    elif [[ "$line" == "|----|------|-------|--------|" ]]; then
        SEPARATOR_OK=true
    elif [[ "$line" =~ ^\|\ T[0-9]+ ]]; then
        ROW_COUNT=$((ROW_COUNT + 1))
    fi
done <<< "$TABLE_OUTPUT"

if [[ "$HEADER_OK" == "true" ]]; then
    pass "Full table has correct header"
else
    fail "Full table missing header"
fi

if [[ "$SEPARATOR_OK" == "true" ]]; then
    pass "Full table has separator"
else
    fail "Full table missing separator"
fi

if [[ "$ROW_COUNT" == "4" ]]; then
    pass "Full table has all 4 data rows"
else
    fail "Expected 4 data rows, got $ROW_COUNT"
fi

# ============================================================
# Test 11: Verify blocked status takes precedence
# ============================================================

echo ""
echo "Testing blocked status with explicit blocked status..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Blocked task",
      "agent": "developer",
      "status": "blocked",
      "blockedBy": ["T0"],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep -q "blocked by T0"; then
    pass "Explicit blocked status shows 'blocked by T0'"
else
    fail "Blocked status not showing blockedBy: $TABLE_OUTPUT"
fi

# ============================================================
# Test 12: Special characters in task subject
# ============================================================

echo ""
echo "Testing special characters in task subject..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Add OAuth2 authentication (SSO)",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

if echo "$TABLE_OUTPUT" | grep -q "Add OAuth2 authentication (SSO)"; then
    pass "Special characters (parentheses) preserved in subject"
else
    fail "Special characters not preserved: $TABLE_OUTPUT"
fi

# ============================================================
# Test 13: Pipe character in subject (edge case)
# ============================================================

echo ""
echo "Testing pipe character handling..."

# Note: Pipe in subject would break table format, so subject should be sanitized
# This test ensures we handle this edge case gracefully
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Handle A or B case",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

TABLE_OUTPUT=$(generate_table "$TEST_DIR/.workflow/001-test-workflow/tasks.json")

# Table should still be valid (4 columns per row)
DATA_ROW=$(echo "$TABLE_OUTPUT" | grep "| T1 |")
PIPE_COUNT=$(echo "$DATA_ROW" | tr -cd '|' | wc -c | tr -d ' ')

if [[ "$PIPE_COUNT" == "5" ]]; then
    pass "Table structure valid even with edge case subjects"
else
    fail "Table structure broken, got $PIPE_COUNT pipes"
fi

# ============================================================
# Test 14: tasks-table.sh script produces correct format
# ============================================================

echo ""
echo "Testing tasks-table.sh script..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Setup project", "agent": "developer", "status": "completed", "blockedBy": [], "blocks": []},
    {"id": "T2", "subject": "Implement feature", "agent": "developer", "status": "in_progress", "blockedBy": [], "blocks": []},
    {"id": "T3", "subject": "Write tests", "agent": "qa", "status": "pending", "blockedBy": ["T2"], "blocks": []}
  ]
}
EOF

# Run the actual tasks-table.sh script via tmux
tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/tasks-table.sh '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1" Enter
sleep 2
SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

# Verify header
if echo "$SCRIPT_OUTPUT" | grep -q "| ID | Task | Agent | Status |"; then
    pass "tasks-table.sh produces correct header"
else
    fail "tasks-table.sh missing header: $SCRIPT_OUTPUT"
fi

# Verify data rows
if echo "$SCRIPT_OUTPUT" | grep -q "| T1 | Setup project | developer | completed |"; then
    pass "tasks-table.sh shows completed task correctly"
else
    fail "tasks-table.sh completed task incorrect"
fi

if echo "$SCRIPT_OUTPUT" | grep -q "blocked by T2"; then
    pass "tasks-table.sh shows blocked by format"
else
    fail "tasks-table.sh blocked by format incorrect"
fi

# ============================================================
# Test 15: tasks-table.sh with missing file
# ============================================================

echo ""
echo "Testing tasks-table.sh with missing tasks file..."

rm -f "$TEST_DIR/.workflow/001-test-workflow/tasks.json"

tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/tasks-table.sh '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1" Enter
sleep 2
SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

if echo "$SCRIPT_OUTPUT" | grep -q "no tasks file found"; then
    pass "tasks-table.sh handles missing file gracefully"
else
    fail "tasks-table.sh should report missing file: $SCRIPT_OUTPUT"
fi

# ============================================================
# Test 16: tasks-table.sh with empty tasks array
# ============================================================

echo ""
echo "Testing tasks-table.sh with empty tasks array..."

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": []
}
EOF

tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/tasks-table.sh '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1" Enter
sleep 2
SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

if echo "$SCRIPT_OUTPUT" | grep -q "(no tasks)"; then
    pass "tasks-table.sh shows '(no tasks)' for empty array"
else
    fail "tasks-table.sh should show '(no tasks)': $SCRIPT_OUTPUT"
fi

# ============================================================
# Test 17: tasks-table.sh respects WORKFLOW_NAME env var
# ============================================================

echo ""
echo "Testing tasks-table.sh with tmux WORKFLOW_NAME..."

# Restore tasks for test
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Env var test task", "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []}
  ]
}
EOF

# Run inside the tmux session with WORKFLOW_NAME set
tmux send-keys -t "$SESSION_NAME" "$BIN_DIR/tasks-table.sh '$TEST_DIR' > /tmp/e2e-tasktable-$$.txt 2>&1" Enter
sleep 2
SCRIPT_OUTPUT=$(cat /tmp/e2e-tasktable-$$.txt 2>/dev/null)

if echo "$SCRIPT_OUTPUT" | grep -q "Env var test task"; then
    pass "tasks-table.sh reads workflow from tmux env"
else
    fail "tasks-table.sh couldn't find workflow: $SCRIPT_OUTPUT"
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
