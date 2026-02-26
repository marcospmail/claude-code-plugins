#!/bin/bash
# test-block-task-guard.sh
#
# E2E Test: PreToolUse hook that blocks agents from using the Task sub-agent tool
#
# This test verifies:
# 1. Hook is registered in hooks.json with matcher "Task"
# 2. Hook blocks PM agents from using Task tool
# 3. Hook blocks developer agents from using Task tool
# 4. Hook blocks QA agents from using Task tool
# 5. Hook allows user/orchestrator (no role) to use Task tool
# 6. PM block message shows team agents (developer, qa) with delegation message
# 7. Developer block message shows only PM with contact message
# 8. Block message includes send_message syntax
# 9. Graceful degradation without agents.yml
# 10. Invalid JSON stdin returns safe fallback
#
# All tests use tmux-based workflow detection (identity.yml + session/window matching).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="block-task-guard"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-task-block-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-hook-output-$TEST_NAME-$TEST_ID"
MAX_WAIT=30

echo "======================================================================"
echo "  E2E Test: Block Task Tool Hook"
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
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/block-task-guard.py"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

# Helper: run hook from a tmux pane and capture output
run_hook_in_pane() {
    local pane="$1"

    rm -f "$OUTPUT_FILE"

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:$pane" \
        "echo '{\"tool_name\":\"Task\",\"tool_input\":{\"prompt\":\"test\",\"subagent_type\":\"general-purpose\"}}' | HOOK_CWD='$TEST_DIR' WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

    local waited=0
    while [[ $waited -lt $MAX_WAIT ]]; do
        if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
            cat "$OUTPUT_FILE"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "TIMEOUT"
    return 1
}

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

if jq -e '.hooks.PreToolUse[] | select(.matcher == "Task") | .hooks[] | select(.command | contains("block-task-guard.py"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "PreToolUse hook configured with matcher 'Task'"
else
    fail "PreToolUse hook not configured correctly in hooks.json"
    exit 1
fi

echo ""

# ============================================================
# Phase 2: Setup test environment with agents.yml + identity.yml
# ============================================================
echo "Phase 2: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/pm"
mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/developer"
mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/qa"

# Create tmux session first to capture pane IDs
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
# Retry session creation if tmux server wasn't ready
for _retry in $(seq 1 5); do
    tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null && break
    sleep 1
    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
done
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow
PM_PANE_ID=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F '#{pane_id}' | head -1)
DEV_PANE_ID=$(tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" -P -F '#{pane_id}' 2>/dev/null)
QA_PANE_ID=$(tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" -P -F '#{pane_id}' 2>/dev/null)
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
sleep 2

# Create agents.yml with pane_id fields
cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << EOF
pm:
  name: pm
  role: pm
  pane_id: "$PM_PANE_ID"
  session: $SESSION_NAME
  window: 0
agents:
  - name: developer
    role: developer
    pane_id: "$DEV_PANE_ID"
    session: $SESSION_NAME
    window: 1
  - name: qa
    role: qa
    pane_id: "$QA_PANE_ID"
    session: $SESSION_NAME
    window: 2
EOF

# Create identity.yml files with pane_id (used by role detection)
cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_ID"
window: 0
workflow: 001-test-workflow
can_modify_code: false
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/developer/identity.yml" << EOF
name: developer
role: developer
model: sonnet
pane_id: "$DEV_PANE_ID"
window: 1
workflow: 001-test-workflow
can_modify_code: true
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/qa/identity.yml" << EOF
name: qa
role: qa
model: sonnet
pane_id: "$QA_PANE_ID"
window: 2
workflow: 001-test-workflow
can_modify_code: test-only
EOF

if [[ -f "$TEST_DIR/.workflow/001-test-workflow/agents.yml" ]]; then
    pass "Created test environment with pane_id-based agents.yml and identity.yml files"
else
    fail "Failed to create test environment"
    exit 1
fi

echo ""

# ============================================================
# Phase 3: Test PM is blocked (via identity.yml detection)
# ============================================================
echo "Phase 3: Testing PM is blocked from Task tool..."

PM_OUTPUT=$(run_hook_in_pane "0")

if echo "$PM_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from using Task tool"
else
    fail "PM should be blocked from Task tool"
fi

if echo "$PM_OUTPUT" | grep -q "BLOCKED.*PM.*sub-agents"; then
    pass "Block message indicates PM blocked from sub-agents"
else
    fail "Block message should indicate PM blocked from sub-agents"
fi

if echo "$PM_OUTPUT" | grep -q "general-purpose"; then
    pass "Block message mentions blocked subagent type"
else
    fail "Block message should mention blocked subagent type"
fi

if echo "$PM_OUTPUT" | grep -q "send-to-agent"; then
    pass "PM block message contains delegation instruction"
else
    fail "PM block message should contain delegation instruction"
fi

echo ""

# ============================================================
# Phase 4: Test developer is blocked (via identity.yml detection)
# ============================================================
echo "Phase 4: Testing developer is blocked from Task tool..."

DEV_OUTPUT=$(run_hook_in_pane "1")

if echo "$DEV_OUTPUT" | grep -q '"block"'; then
    pass "Developer blocked from using Task tool"
else
    fail "Developer should be blocked from Task tool"
fi

if echo "$DEV_OUTPUT" | grep -q "You are a developer agent"; then
    pass "Block message mentions developer role"
else
    fail "Block message should mention developer role"
fi

if echo "$DEV_OUTPUT" | grep -q "contact your PM to coordinate work"; then
    pass "Developer block message contains PM contact instruction"
else
    fail "Developer block message should contain PM contact instruction"
fi

echo ""

# ============================================================
# Phase 5: Test QA is blocked (via identity.yml detection)
# ============================================================
echo "Phase 5: Testing QA is blocked from Task tool..."

QA_OUTPUT=$(run_hook_in_pane "2")

if echo "$QA_OUTPUT" | grep -q '"block"'; then
    pass "QA blocked from using Task tool"
else
    fail "QA should be blocked from Task tool"
fi

if echo "$QA_OUTPUT" | grep -q "You are a qa agent"; then
    pass "Block message mentions QA role"
else
    fail "Block message should mention QA role"
fi

echo ""

# ============================================================
# Phase 6: Test user/orchestrator is allowed (no matching identity.yml)
# ============================================================
echo "Phase 6: Testing user/orchestrator is allowed..."

# Window 3 has no matching identity.yml
ORCH_OUTPUT=$(run_hook_in_pane "3")

if echo "$ORCH_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "User/orchestrator allowed to use Task tool"
else
    fail "User/orchestrator should be allowed to use Task tool"
fi

echo ""

# ============================================================
# Phase 7: Test send_message syntax in block message
# ============================================================
echo "Phase 7: Testing send_message syntax in block message..."

SYNTAX_OUTPUT=$(run_hook_in_pane "1")

if echo "$SYNTAX_OUTPUT" | grep -q "Send a message with:"; then
    pass "Block message includes 'Send a message with:'"
else
    fail "Block message should include send message instructions"
fi

if echo "$SYNTAX_OUTPUT" | grep -q "uv run --project.*python.*tmux_utils.py send"; then
    pass "Block message includes send command syntax"
else
    fail "Block message should include uv run python command syntax"
fi

echo ""

# ============================================================
# Phase 8: Test graceful degradation without agents.yml
# ============================================================
echo "Phase 8: Testing graceful degradation without agents.yml..."

# Create a separate test dir without agents.yml but with PM identity (using pane_id)
NO_AGENTS_DIR="/tmp/e2e-test-no-agents-$TEST_ID"
mkdir -p "$NO_AGENTS_DIR/.workflow/001-test/agents/pm"
cat > "$NO_AGENTS_DIR/.workflow/001-test/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_ID"
window: 0
workflow: 001-test
can_modify_code: false
EOF

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" \
    "echo '{\"tool_name\":\"Task\",\"tool_input\":{\"prompt\":\"test\",\"subagent_type\":\"general-purpose\"}}' | HOOK_CWD='$NO_AGENTS_DIR' WORKFLOW_NAME=001-test TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

NO_AGENTS_OUTPUT=$(cat "$OUTPUT_FILE" 2>/dev/null)

if echo "$NO_AGENTS_OUTPUT" | grep -q '"block"'; then
    pass "Still blocks PM even without agents.yml"
else
    fail "Should still block PM without agents.yml"
fi

if echo "$NO_AGENTS_OUTPUT" | grep -q "send-to-agent"; then
    pass "PM sees delegation instruction even without agents.yml"
else
    fail "PM should see delegation instruction even without agents.yml"
fi

rm -rf "$NO_AGENTS_DIR"

echo ""

# ============================================================
# Phase 9: Test invalid JSON stdin returns safe fallback
# ============================================================
echo "Phase 9: Testing invalid JSON stdin returns safe fallback..."

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" \
    "echo 'not valid json' | HOOK_CWD='$TEST_DIR' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

INVALID_OUTPUT=$(cat "$OUTPUT_FILE" 2>/dev/null)

if echo "$INVALID_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Invalid JSON returns safe fallback {continue: true}"
else
    fail "Invalid JSON should return safe fallback"
fi

echo ""

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    exit 1
fi
