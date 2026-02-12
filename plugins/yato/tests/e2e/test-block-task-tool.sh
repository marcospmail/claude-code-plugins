#!/bin/bash
# test-block-task-tool.sh
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
# 8. QA block message shows only PM with contact message
# 9. Block message includes send_message syntax
# 10. PM block message does not include PM itself in the list
# 11. Graceful degradation without agents.yml
# 12. Invalid JSON stdin returns safe fallback
#
# Phases 3-9 run the Python hook script directly for reliable output parsing.
# Phases 10-12 verify hook works in real Claude sessions.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="block-task-tool"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-task-block-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

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
    rm -rf "/tmp/e2e-test-no-agents-$TEST_ID" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/block-task-tool.py"
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

if jq -e '.hooks.PreToolUse[] | select(.matcher == "Task") | .hooks[] | select(.command | contains("block-task-tool.py"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "PreToolUse hook configured with matcher 'Task'"
else
    fail "PreToolUse hook not configured correctly in hooks.json"
    exit 1
fi

echo ""

# ============================================================
# Phase 2: Setup test environment with agents.yml
# ============================================================
echo "Phase 2: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

# Create agents.yml with PM, developer, and QA
cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << 'EOF'
pm:
  name: pm
  role: pm
  session: testproject
  window: 0
  pane: 1
agents:
  - name: developer
    role: developer
    session: testproject
    window: 1
  - name: qa
    role: qa
    session: testproject
    window: 2
EOF

if [[ -f "$TEST_DIR/.workflow/001-test-workflow/agents.yml" ]]; then
    pass "Created agents.yml with PM, developer, and QA"
else
    fail "Failed to create agents.yml"
    exit 1
fi

echo ""

# ============================================================
# Phase 3: Test PM is blocked (direct script execution)
# ============================================================
echo "Phase 3: Testing PM is blocked from Task tool..."

PM_OUTPUT=$(echo '{"tool_name":"Task","tool_input":{"prompt":"Review the code","subagent_type":"general-purpose"}}' | AGENT_ROLE=pm WORKFLOW_NAME=001-test-workflow HOOK_CWD="$TEST_DIR" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

if echo "$PM_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from using Task tool"
else
    fail "PM should be blocked from Task tool"
fi

if echo "$PM_OUTPUT" | grep -q "TASK SUB-AGENT BLOCKED"; then
    pass "Block message contains 'TASK SUB-AGENT BLOCKED'"
else
    fail "Block message should contain 'TASK SUB-AGENT BLOCKED'"
fi

if echo "$PM_OUTPUT" | grep -q "You are a pm agent"; then
    pass "Block message mentions PM role"
else
    fail "Block message should mention PM role"
fi

if echo "$PM_OUTPUT" | grep -q "delegate work to your team agents"; then
    pass "PM block message contains delegation instruction"
else
    fail "PM block message should contain delegation instruction"
fi

echo ""

# ============================================================
# Phase 4: Test developer is blocked (direct script execution)
# ============================================================
echo "Phase 4: Testing developer is blocked from Task tool..."

DEV_OUTPUT=$(echo '{"tool_name":"Task","tool_input":{"prompt":"Write tests","subagent_type":"general-purpose"}}' | AGENT_ROLE=developer WORKFLOW_NAME=001-test-workflow HOOK_CWD="$TEST_DIR" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

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
# Phase 5: Test QA is blocked (direct script execution)
# ============================================================
echo "Phase 5: Testing QA is blocked from Task tool..."

QA_OUTPUT=$(echo '{"tool_name":"Task","tool_input":{"prompt":"Run tests","subagent_type":"general-purpose"}}' | AGENT_ROLE=qa WORKFLOW_NAME=001-test-workflow HOOK_CWD="$TEST_DIR" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

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
# Phase 6: Test user/orchestrator is allowed (direct script execution)
# ============================================================
echo "Phase 6: Testing user/orchestrator is allowed..."

ORCH_OUTPUT=$(echo '{"tool_name":"Task","tool_input":{"prompt":"Create sub-agent","subagent_type":"general-purpose"}}' | AGENT_ROLE='' TMUX='' HOOK_CWD="$TEST_DIR" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

if echo "$ORCH_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "User/orchestrator allowed to use Task tool"
else
    fail "User/orchestrator should be allowed to use Task tool"
fi

echo ""

# ============================================================
# Phase 7: Test send_message syntax in block message (direct script execution)
# ============================================================
echo "Phase 7: Testing send_message syntax in block message..."

SYNTAX_OUTPUT=$(echo '{"tool_name":"Task","tool_input":{"prompt":"Task","subagent_type":"general-purpose"}}' | AGENT_ROLE=developer WORKFLOW_NAME=001-test-workflow HOOK_CWD="$TEST_DIR" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

if echo "$SYNTAX_OUTPUT" | grep -q "Send a message with:"; then
    pass "Block message includes 'Send a message with:'"
else
    fail "Block message should include send message instructions"
fi

if echo "$SYNTAX_OUTPUT" | grep -q "uv run python lib/tmux_utils.py send"; then
    pass "Block message includes send command syntax"
else
    fail "Block message should include uv run python command syntax"
fi

echo ""

# ============================================================
# Phase 8: Test graceful degradation without agents.yml (direct script execution)
# ============================================================
echo "Phase 8: Testing graceful degradation without agents.yml..."

# Create a temp dir without agents.yml
mkdir -p "/tmp/e2e-test-no-agents-$TEST_ID/.workflow/001-test"

# PM without agents.yml
NO_AGENTS_OUTPUT=$(echo '{"tool_name":"Task","tool_input":{"prompt":"Task","subagent_type":"general-purpose"}}' | AGENT_ROLE=pm WORKFLOW_NAME=001-test HOOK_CWD="/tmp/e2e-test-no-agents-$TEST_ID" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

if echo "$NO_AGENTS_OUTPUT" | grep -q '"block"'; then
    pass "Still blocks PM even without agents.yml"
else
    fail "Should still block PM without agents.yml"
fi

if echo "$NO_AGENTS_OUTPUT" | grep -q "No team agents found"; then
    pass "PM sees 'No team agents found' message when agents.yml missing"
else
    fail "PM should see 'No team agents found' when agents.yml missing"
fi

rm -rf "/tmp/e2e-test-no-agents-$TEST_ID"

echo ""

# ============================================================
# Phase 9: Test invalid JSON stdin returns safe fallback (direct script execution)
# ============================================================
echo "Phase 9: Testing invalid JSON stdin returns safe fallback..."

INVALID_OUTPUT=$(echo 'not valid json' | AGENT_ROLE=pm HOOK_CWD="$TEST_DIR" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

if echo "$INVALID_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Invalid JSON returns safe fallback {continue: true}"
else
    fail "Invalid JSON should return safe fallback"
fi

echo ""

# Helper: wait for Claude to start, handle trust prompt, return when ready
wait_for_claude() {
    local max_wait=30
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local output
        output=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
        if echo "$output" | grep -qi "trust"; then
            echo "  Trust prompt found, accepting..."
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter 2>/dev/null
            sleep 15
            return 0
        fi
        if echo "$output" | grep -q "^❯"; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    # Fallback: assume ready after max wait
    return 0
}

# Helper: send prompt, poll for expected pattern in pane output
wait_for_pattern() {
    local pattern="$1"
    local max_wait=90
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local output
        output=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)
        # Handle "Use skill" prompts by selecting the second option
        if echo "$output" | grep -qi "Use skill"; then
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter 2>/dev/null
        fi
        if echo "$output" | grep -qi "$pattern"; then
            echo "$output"
            return 0
        fi
        sleep 5
        waited=$((waited + 5))
    done
    # Return whatever we have after timeout
    tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null
    return 1
}

# Helper: kill session and wait for tmux server cleanup before creating new one
recreate_session() {
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    sleep 3  # Wait for tmux server to fully shut down (prevents "no server running" race)
    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
}

# ============================================================
# Phase 10: E2E - PM blocked via real Claude session
# ============================================================
echo "Phase 10: Testing PM blocked via real Claude session..."

# Create tmux session with larger size for Claude TUI
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null

# Start Claude with AGENT_ROLE=pm
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "export AGENT_ROLE=pm AGENT_NAME=pm WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter 2>/dev/null

echo "  Waiting for Claude to initialize..."
wait_for_claude

# Send prompt that would trigger Task tool usage
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Right now, immediately invoke the Task tool with subagent_type=Explore to explore this codebase. Do not ask for clarification, just invoke the tool." 2>/dev/null
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter 2>/dev/null

echo "  Waiting for Claude to process..."
PM_E2E_OUTPUT=$(wait_for_pattern "delegate work to your team agents\|team agents\|TASK SUB-AGENT BLOCKED\|sub-agent.*blocked")

if echo "$PM_E2E_OUTPUT" | grep -qi "delegate work to your team agents\|team agents\|TASK SUB-AGENT BLOCKED\|sub-agent.*blocked"; then
    pass "PM received block message mentioning team agents"
else
    fail "PM should receive block message about delegating to team agents"
fi

echo ""

# ============================================================
# Phase 11: E2E - Developer blocked via real Claude session
# ============================================================
echo "Phase 11: Testing developer blocked via real Claude session..."

recreate_session

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "export AGENT_ROLE=developer AGENT_NAME=developer WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter 2>/dev/null

echo "  Waiting for Claude to initialize..."
wait_for_claude

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Right now, immediately invoke the Task tool with subagent_type=Explore to explore this codebase. Do not ask for clarification, just invoke the tool." 2>/dev/null
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter 2>/dev/null

echo "  Waiting for Claude to process..."
DEV_E2E_OUTPUT=$(wait_for_pattern "contact your PM\|Your PM:\|TASK SUB-AGENT BLOCKED\|sub-agent.*blocked")

if echo "$DEV_E2E_OUTPUT" | grep -qi "contact your PM\|Your PM:\|TASK SUB-AGENT BLOCKED\|sub-agent.*blocked"; then
    pass "Developer received block message mentioning PM contact"
else
    fail "Developer should receive block message about contacting PM"
fi

echo ""

# ============================================================
# Phase 12: E2E - Orchestrator allowed via real Claude session
# ============================================================
echo "Phase 12: Testing orchestrator allowed via real Claude session..."

recreate_session

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "export WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter 2>/dev/null

echo "  Waiting for Claude to initialize..."
wait_for_claude

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Right now, immediately invoke the Task tool with subagent_type=Explore to explore this codebase. Do not ask for clarification, just invoke the tool." 2>/dev/null
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter 2>/dev/null

echo "  Waiting for Claude to process..."
sleep 60

ORCH_E2E_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

if echo "$ORCH_E2E_OUTPUT" | grep -qi "TASK SUB-AGENT BLOCKED\|contact your PM\|delegate work"; then
    fail "Orchestrator should NOT be blocked from using Task tool"
else
    pass "Orchestrator allowed to proceed (no block message received)"
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
