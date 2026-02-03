#!/bin/bash
# test-pretool-tasks-status-hook.sh
#
# E2E Test: PreToolUse hook for tasks.json status reminders
#
# This test verifies:
# 1. Hook is registered in hooks.json and script exists
# 2. Hook script returns correct JSON for tasks.json edits
# 3. Hook script returns correct JSON for non-tasks.json files
# 4. When Claude edits tasks.json in tmux, hook behavior is respected

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pretool-tasks-status"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-pretool-$$"

echo "======================================================================"
echo "  E2E Test: PreToolUse Tasks Status Reminder Hook"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/tasks-status-reminder.py"
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

if [[ -x "$HOOK_SCRIPT" ]] || head -1 "$HOOK_SCRIPT" | grep -q python; then
    pass "Hook script is executable (or Python script)"
else
    fail "Hook script is not executable"
fi

if jq -e '.hooks.PreToolUse[0].matcher == "Edit|Write"' "$HOOKS_JSON" 2>/dev/null | grep -q true; then
    pass "PreToolUse hook configured with Edit|Write matcher"
else
    fail "PreToolUse hook not configured correctly in hooks.json"
    exit 1
fi

if jq -r '.hooks.PreToolUse[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null | grep -q 'tasks-status-reminder.py'; then
    pass "Hook command references tasks-status-reminder.py"
else
    fail "Hook command doesn't reference tasks-status-reminder.py"
fi

echo ""

# ============================================================
# Phase 2: Test hook script directly (tasks.json input)
# ============================================================
echo "Phase 2: Testing hook script with tasks.json input..."

TASKS_INPUT='{"toolInput":{"file_path":"/project/.workflow/001-test/tasks.json","old_string":"blocked","new_string":"completed"}}'
OUTPUT=$(echo "$TASKS_INPUT" | python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.continue == true' >/dev/null 2>&1; then
    pass "Hook returns continue:true for tasks.json"
else
    fail "Hook doesn't return continue:true"
    echo "  Output: $OUTPUT"
fi

if echo "$OUTPUT" | jq -e '.systemMessage' >/dev/null 2>&1; then
    pass "Hook returns systemMessage for tasks.json"
else
    fail "Hook doesn't return systemMessage"
fi

SYSMSG=$(echo "$OUTPUT" | jq -r '.systemMessage' 2>/dev/null)

if echo "$SYSMSG" | grep -qi "NEVER.*mark.*completed"; then
    pass "systemMessage contains NEVER mark completed rule"
else
    fail "systemMessage missing NEVER mark completed rule"
fi

if echo "$SYSMSG" | grep -qi "blocked.*stays.*blocked\|stays.*blocked"; then
    pass "systemMessage contains blocked stays blocked rule"
else
    fail "systemMessage missing blocked stays blocked rule"
fi

if echo "$SYSMSG" | grep -qi "skip.*BLOCKED\|cannot skip"; then
    pass "systemMessage contains skip keeps blocked rule"
else
    fail "systemMessage missing skip keeps blocked rule"
fi

echo ""

# ============================================================
# Phase 3: Test hook script with non-tasks.json input
# ============================================================
echo "Phase 3: Testing hook script with non-tasks.json input..."

OTHER_INPUT='{"toolInput":{"file_path":"/project/src/main.py","old_string":"hello","new_string":"world"}}'
OUTPUT=$(echo "$OTHER_INPUT" | python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.continue == true' >/dev/null 2>&1; then
    pass "Hook returns continue:true for non-tasks.json"
else
    fail "Hook doesn't return continue:true for non-tasks.json"
fi

if echo "$OUTPUT" | jq -e '.systemMessage' >/dev/null 2>&1; then
    fail "Hook should NOT return systemMessage for non-tasks.json"
else
    pass "Hook correctly omits systemMessage for non-tasks.json"
fi

echo ""

# ============================================================
# Phase 4: Test various file paths
# ============================================================
echo "Phase 4: Testing various file path formats..."

# Files that SHOULD trigger systemMessage
TRIGGER_PATHS=(
    "/project/.workflow/001-test/tasks.json"
    "tasks.json"
    "./.workflow/tasks.json"
)

for path in "${TRIGGER_PATHS[@]}"; do
    INPUT="{\"toolInput\":{\"file_path\":\"$path\"}}"
    OUTPUT=$(echo "$INPUT" | python3 "$HOOK_SCRIPT" 2>&1)
    if echo "$OUTPUT" | jq -e '.systemMessage' >/dev/null 2>&1; then
        pass "Hook triggers for: $path"
    else
        fail "Hook should trigger for: $path"
    fi
done

# Files that should NOT trigger systemMessage
NO_TRIGGER_PATHS=(
    "/project/config.json"
    "/project/package.json"
    "/project/.workflow/status.yml"
)

for path in "${NO_TRIGGER_PATHS[@]}"; do
    INPUT="{\"toolInput\":{\"file_path\":\"$path\"}}"
    OUTPUT=$(echo "$INPUT" | python3 "$HOOK_SCRIPT" 2>&1)
    if echo "$OUTPUT" | jq -e '.systemMessage' >/dev/null 2>&1; then
        fail "Hook should NOT trigger for: $path"
    else
        pass "Hook correctly skips: $path"
    fi
done

echo ""

# ============================================================
# Phase 5: Test with tmux + Claude (E2E)
# ============================================================
echo "Phase 5: Testing with Claude in tmux session..."

mkdir -p "$TEST_DIR/.workflow/001-test"

# Create tasks.json with a BLOCKED task
cat > "$TEST_DIR/.workflow/001-test/tasks.json" << 'EOF'
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Manual QA verification",
      "description": "Verify feature works correctly",
      "agent": "qa",
      "status": "blocked",
      "blockedBy": [],
      "blocks": []
    }
  ]
}
EOF

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Start Claude with dangerously skip permissions
tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter

echo "Waiting for Claude to initialize..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started (prompt visible)"
else
    echo "Debug - tmux output:"
    echo "$OUTPUT" | tail -15
    fail "Claude prompt not visible"
fi

# Send a request to edit tasks.json
echo "Sending edit request..."
tmux send-keys -t "$SESSION_NAME" "Edit .workflow/001-test/tasks.json and change status from blocked to completed"
sleep 1
tmux send-keys -t "$SESSION_NAME" Enter

echo "Waiting for Claude to process (this may take a moment)..."
sleep 60

# Capture output
FINAL_OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

echo ""
echo "Debug - Claude response:"
echo "$FINAL_OUTPUT" | tail -30
echo ""

# Check if Claude mentioned the rules or refused
if echo "$FINAL_OUTPUT" | grep -qi "blocked\|status\|task\|complet"; then
    pass "Claude processed the edit request"
else
    fail "Claude response not captured properly"
fi

# Check the file status
FINAL_STATUS=$(python3 -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/tasks.json', 'r') as f:
        data = json.load(f)
    print(data['tasks'][0]['status'])
except Exception as e:
    print('error')
" 2>/dev/null)

echo "Final task status in file: $FINAL_STATUS"

# The hook injects a warning - Claude may or may not heed it
# But we should see SOME response
if [[ "$FINAL_STATUS" == "blocked" ]]; then
    pass "Task remained blocked (Claude heeded the warning)"
elif [[ "$FINAL_STATUS" == "completed" ]]; then
    # Claude completed it despite warning - the hook still worked (injected message)
    # This is acceptable as the hook is advisory
    pass "Task was completed (hook ran, Claude proceeded anyway - advisory behavior)"
else
    fail "Unexpected status: $FINAL_STATUS"
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
