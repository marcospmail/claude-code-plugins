#!/bin/bash
# test-block-task-tool.sh
#
# E2E Test: PreToolUse hook that blocks agents from using the Task sub-agent tool
#
# This test verifies:
# UNIT TESTS (Python script direct execution):
# 1. Hook is registered in hooks.json with matcher "Task"
# 2. Hook blocks PM agents from using Task tool
# 3. Hook blocks developer agents from using Task tool
# 4. Hook blocks QA agents from using Task tool
# 5. Hook allows user/orchestrator (no role) to use Task tool
# 6. PM block message shows team agents (developer, qa) with delegation message
# 7. Developer block message shows only PM with contact message
# 8. QA block message shows only PM with contact message
# 9. Block message includes send_message syntax with "uv run python lib/tmux_utils.py send"
# 10. PM block message does not include PM itself in the list
# 11. Graceful degradation without agents.yml (role-specific fallback messages)
# 12. Invalid JSON stdin returns safe fallback {"continue": true}
#
# E2E TESTS (Real tmux + Claude CLI):
# 13. PM in tmux session receives block message when trying to use Task tool
# 14. Developer in tmux session receives block message when trying to use Task tool
# 15. Orchestrator (no role) in tmux session can use Task tool
# 16. PM sees team agents in block message (Claude receives the guidance)
# 17. Developer sees only PM in block message (Claude receives the guidance)

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

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/block-task-tool.py"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

echo "======================================================================"
echo "  UNIT TESTS (Direct Python Script Execution)"
echo "======================================================================"
echo ""

# ============================================================
# Unit Test Phase 1: Verify hook configuration
# ============================================================
echo "Unit Test Phase 1: Checking hook configuration..."

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
# Unit Test Phase 2: Setup test environment with agents.yml
# ============================================================
echo "Unit Test Phase 2: Setting up test environment..."

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

echo "Test directory: $TEST_DIR"
echo ""

# ============================================================
# Unit Test Phase 3: Test PM is blocked
# ============================================================
echo "Unit Test Phase 3: Testing PM is blocked from Task tool..."

cd "$TEST_DIR"

INPUT='{"tool_name":"Task","tool_input":{"prompt":"Review the code","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=pm WORKFLOW_NAME=001-test-workflow python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass "PM blocked from using Task tool"
else
    fail "PM should be blocked from Task tool"
    echo "  Output: $OUTPUT"
fi

# Verify block message content for PM
REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)
if echo "$REASON" | grep -q "TASK SUB-AGENT BLOCKED"; then
    pass "Block message contains 'TASK SUB-AGENT BLOCKED'"
else
    fail "Block message should contain 'TASK SUB-AGENT BLOCKED'"
fi

if echo "$REASON" | grep -q "You are a pm agent"; then
    pass "Block message mentions PM role"
else
    fail "Block message should mention PM role"
fi

if echo "$REASON" | grep -q "delegate work to your team agents"; then
    pass "PM block message contains delegation instruction"
else
    fail "PM block message should contain 'delegate work to your team agents'"
fi

if echo "$REASON" | grep -q "Your team agents:"; then
    pass "PM block message has 'Your team agents:' header"
else
    fail "PM block message should have 'Your team agents:' header"
fi

if echo "$REASON" | grep -q "developer (developer) at testproject:1"; then
    pass "PM sees developer in team list"
else
    fail "PM should see developer in team list"
fi

if echo "$REASON" | grep -q "qa (qa) at testproject:2"; then
    pass "PM sees qa in team list"
else
    fail "PM should see qa in team list"
fi

if ! echo "$REASON" | grep -q "pm (pm)"; then
    pass "PM does not see itself in the team list"
else
    fail "PM should NOT see itself in the team list"
fi

echo ""

# ============================================================
# Unit Test Phase 4: Test developer is blocked
# ============================================================
echo "Unit Test Phase 4: Testing developer is blocked from Task tool..."

INPUT='{"tool_name":"Task","tool_input":{"prompt":"Write tests","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=developer WORKFLOW_NAME=001-test-workflow python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass "Developer blocked from using Task tool"
else
    fail "Developer should be blocked from Task tool"
    echo "  Output: $OUTPUT"
fi

REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)
if echo "$REASON" | grep -q "You are a developer agent"; then
    pass "Block message mentions developer role"
else
    fail "Block message should mention developer role"
fi

if echo "$REASON" | grep -q "contact your PM to coordinate work"; then
    pass "Developer block message contains PM contact instruction"
else
    fail "Developer block message should contain 'contact your PM to coordinate work'"
fi

if echo "$REASON" | grep -q "Your PM: pm at testproject:0.1"; then
    pass "Developer sees PM target"
else
    fail "Developer should see 'Your PM: pm at testproject:0.1'"
fi

if ! echo "$REASON" | grep -q "qa (qa)"; then
    pass "Developer does not see QA in message"
else
    fail "Developer should NOT see QA in message"
fi

echo ""

# ============================================================
# Unit Test Phase 5: Test QA is blocked
# ============================================================
echo "Unit Test Phase 5: Testing QA is blocked from Task tool..."

INPUT='{"tool_name":"Task","tool_input":{"prompt":"Run tests","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=qa WORKFLOW_NAME=001-test-workflow python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass "QA blocked from using Task tool"
else
    fail "QA should be blocked from Task tool"
    echo "  Output: $OUTPUT"
fi

REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)
if echo "$REASON" | grep -q "You are a qa agent"; then
    pass "Block message mentions QA role"
else
    fail "Block message should mention QA role"
fi

if echo "$REASON" | grep -q "contact your PM to coordinate work"; then
    pass "QA block message contains PM contact instruction"
else
    fail "QA block message should contain 'contact your PM to coordinate work'"
fi

if echo "$REASON" | grep -q "Your PM: pm at testproject:0.1"; then
    pass "QA sees PM target"
else
    fail "QA should see 'Your PM: pm at testproject:0.1'"
fi

if ! echo "$REASON" | grep -q "developer (developer)"; then
    pass "QA does not see developer in message"
else
    fail "QA should NOT see developer in message"
fi

echo ""

# ============================================================
# Unit Test Phase 6: Test user/orchestrator is allowed (no role)
# ============================================================
echo "Unit Test Phase 6: Testing user/orchestrator is allowed..."

# Unset TMUX to prevent tmux env var lookups
INPUT='{"tool_name":"Task","tool_input":{"prompt":"Create sub-agent","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE="" TMUX="" python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.continue == true' >/dev/null 2>&1; then
    pass "User/orchestrator allowed to use Task tool"
else
    fail "User/orchestrator should be allowed to use Task tool"
    echo "  Output: $OUTPUT"
fi

echo ""

# ============================================================
# Unit Test Phase 7: Test developer sees only PM
# ============================================================
echo "Unit Test Phase 7: Testing developer sees only PM..."

INPUT='{"tool_name":"Task","tool_input":{"prompt":"Create sub-agent","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=developer WORKFLOW_NAME=001-test-workflow python3 "$HOOK_SCRIPT" 2>&1)
REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)

if echo "$REASON" | grep -q "Your PM: pm at testproject:0.1"; then
    pass "Developer block message shows PM target"
else
    fail "Developer should see 'Your PM: pm at testproject:0.1'"
fi

if ! echo "$REASON" | grep -q "Available teammates:"; then
    pass "Developer does not see 'Available teammates:' header (old behavior)"
else
    fail "Developer should not see old 'Available teammates:' header"
fi

if ! echo "$REASON" | grep -q "qa (qa)"; then
    pass "Developer does not see QA in message"
else
    fail "Developer should only see PM, not other team members"
fi

if ! echo "$REASON" | grep -q "developer (developer) at testproject:1"; then
    pass "Developer does not see itself in message"
else
    fail "Developer should not see itself in message"
fi

echo ""

# ============================================================
# Unit Test Phase 8: Test send_message syntax in block message
# ============================================================
echo "Unit Test Phase 8: Testing send_message syntax in block message..."

if echo "$REASON" | grep -q "Send a message with:"; then
    pass "Block message includes 'Send a message with:'"
else
    fail "Block message should include send message instructions"
fi

if echo "$REASON" | grep -q "uv run python lib/tmux_utils.py send"; then
    pass "Block message includes 'uv run python lib/tmux_utils.py send' syntax"
else
    fail "Block message should include uv run python command syntax"
    echo "  Expected: uv run python lib/tmux_utils.py send"
fi

if echo "$REASON" | grep -q "Example:"; then
    pass "Block message includes example command"
else
    fail "Block message should include example command"
fi

if echo "$REASON" | grep -q 'testproject:0.1 "I need help with this task'; then
    pass "Developer example uses PM target (testproject:0.1)"
else
    fail "Developer example should use PM target testproject:0.1"
fi

echo ""

# ============================================================
# Unit Test Phase 9: Test PM block message content
# ============================================================
echo "Unit Test Phase 9: Testing PM block message content..."

INPUT='{"tool_name":"Task","tool_input":{"prompt":"Task","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=pm WORKFLOW_NAME=001-test-workflow python3 "$HOOK_SCRIPT" 2>&1)
REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)

if echo "$REASON" | grep -q "delegate work to your team agents"; then
    pass "PM sees delegation instruction"
else
    fail "PM should see 'delegate work to your team agents'"
fi

if echo "$REASON" | grep -q "Your team agents:"; then
    pass "PM sees 'Your team agents:' header"
else
    fail "PM should see 'Your team agents:' header"
fi

if echo "$REASON" | grep -q "developer (developer) at testproject:1"; then
    pass "PM sees developer in team list"
else
    fail "PM should see developer in team list"
fi

if echo "$REASON" | grep -q "qa (qa) at testproject:2"; then
    pass "PM sees qa in team list"
else
    fail "PM should see qa in team list"
fi

if ! echo "$REASON" | grep -q "pm (pm)"; then
    pass "PM does not see itself in team list"
else
    fail "PM should NOT see itself in team list"
fi

if echo "$REASON" | grep -q 'testproject:1 "Please implement the login feature"'; then
    pass "PM example uses first team agent (developer at testproject:1)"
else
    fail "PM example should use first team agent target"
fi

echo ""

# ============================================================
# Unit Test Phase 10: Test graceful degradation without agents.yml
# ============================================================
echo "Unit Test Phase 10: Testing graceful degradation without agents.yml..."

mkdir -p "/tmp/e2e-test-no-agents-$TEST_ID/.workflow/001-test"
cd "/tmp/e2e-test-no-agents-$TEST_ID"

# Test PM without agents.yml
INPUT='{"tool_name":"Task","tool_input":{"prompt":"Task","subagent_type":"general-purpose"}}'
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=pm WORKFLOW_NAME=001-test python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass "Still blocks PM even without agents.yml"
else
    fail "Should still block PM without agents.yml"
fi

REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)
if echo "$REASON" | grep -q "No team agents found in agents.yml"; then
    pass "PM sees 'No team agents found' message when agents.yml missing"
else
    fail "PM should see 'No team agents found' when agents.yml missing"
fi

if echo "$REASON" | grep -q "Deploy agents first with the orchestrator"; then
    pass "PM sees suggestion to deploy agents"
else
    fail "PM should see 'Deploy agents first with the orchestrator'"
fi

# Test developer without agents.yml
OUTPUT=$(echo "$INPUT" | AGENT_ROLE=developer WORKFLOW_NAME=001-test python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.decision == "block"' >/dev/null 2>&1; then
    pass "Still blocks developer even without agents.yml"
else
    fail "Should still block developer without agents.yml"
fi

REASON=$(echo "$OUTPUT" | jq -r '.reason' 2>/dev/null)
if echo "$REASON" | grep -q "No PM found in agents.yml"; then
    pass "Developer sees 'No PM found' message when agents.yml missing"
else
    fail "Developer should see 'No PM found' when agents.yml missing"
fi

if echo "$REASON" | grep -q "Contact the orchestrator for guidance"; then
    pass "Developer sees suggestion to contact orchestrator"
else
    fail "Developer should see 'Contact the orchestrator for guidance'"
fi

rm -rf "/tmp/e2e-test-no-agents-$TEST_ID"

echo ""

# ============================================================
# Unit Test Phase 11: Test invalid JSON stdin returns safe fallback
# ============================================================
echo "Unit Test Phase 11: Testing invalid JSON stdin returns safe fallback..."

cd "$TEST_DIR"

# Send invalid JSON
OUTPUT=$(echo "not valid json" | AGENT_ROLE=pm python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.continue == true' >/dev/null 2>&1; then
    pass "Invalid JSON returns safe fallback {continue: true}"
else
    fail "Invalid JSON should return safe fallback"
    echo "  Output: $OUTPUT"
fi

# Send empty input
OUTPUT=$(echo "" | AGENT_ROLE=pm python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT" | jq -e '.continue == true' >/dev/null 2>&1; then
    pass "Empty input returns safe fallback"
else
    fail "Empty input should return safe fallback"
fi

echo ""

echo "======================================================================"
echo "  E2E TESTS (Real Tmux + Claude CLI)"
echo "======================================================================"
echo ""

# ============================================================
# E2E Test Phase 1: PM blocked via real Claude session
# ============================================================
echo "E2E Test Phase 1: Testing PM blocked via real Claude session..."

# Create tmux session
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Set WORKFLOW_NAME at session level (needed for workflow path discovery)
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

# Export env vars directly in shell and start Claude (most reliable approach)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "export AGENT_ROLE=pm AGENT_NAME=pm WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter

pass "Started Claude with AGENT_ROLE=pm"

echo "Waiting for Claude to initialize..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started (prompt visible)"
else
    echo "Debug - tmux output:"
    echo "$OUTPUT" | tail -15
    fail "Claude prompt not visible"
fi

# Send prompt that would trigger Task tool usage
echo "Sending request to use Task tool..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Right now, immediately invoke the Task tool with subagent_type=Explore to explore this codebase. Do not ask for clarification, just invoke the tool."
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter

echo "Waiting for Claude to process (60 seconds)..."
sleep 60

# Capture output
PM_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

echo ""
echo "Debug - Claude response (last 30 lines):"
echo "$PM_OUTPUT" | tail -30
echo ""

# Verify PM received block message with team agents
if echo "$PM_OUTPUT" | grep -qi "delegate work to your team agents\|team agents\|developer"; then
    pass "PM received block message mentioning team agents"
else
    fail "PM should receive block message about delegating to team agents"
fi

# Kill session and create new one for next test (cleanest approach)
echo "Stopping session for next test..."
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null

echo ""

# ============================================================
# E2E Test Phase 2: Developer blocked via real Claude session
# ============================================================
echo "E2E Test Phase 2: Testing developer blocked via real Claude session..."

# Create fresh tmux session for developer test
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session for developer test"
    exit 1
fi

# Set WORKFLOW_NAME at session level (needed for workflow path discovery)
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"

# Export env vars and start Claude
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "export AGENT_ROLE=developer AGENT_NAME=developer WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter

pass "Started Claude with AGENT_ROLE=developer"

echo "Waiting for Claude to initialize..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started (prompt visible)"
else
    fail "Claude prompt not visible"
fi

# Send same Task tool request
echo "Sending request to use Task tool..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Right now, immediately invoke the Task tool with subagent_type=Explore to explore this codebase. Do not ask for clarification, just invoke the tool."
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter

echo "Waiting for Claude to process (60 seconds)..."
sleep 60

# Capture output
DEV_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

echo ""
echo "Debug - Claude response (last 30 lines):"
echo "$DEV_OUTPUT" | tail -30
echo ""

# Verify developer received block message with PM contact info
if echo "$DEV_OUTPUT" | grep -qi "contact your PM\|Your PM:"; then
    pass "Developer received block message mentioning PM contact"
else
    fail "Developer should receive block message about contacting PM"
fi

# Kill session and create new one for next test
echo "Stopping session for next test..."
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null

echo ""

# ============================================================
# E2E Test Phase 3: Orchestrator allowed via real Claude session
# ============================================================
echo "E2E Test Phase 3: Testing orchestrator allowed via real Claude session..."

# Create fresh tmux session for orchestrator test (no AGENT_ROLE = orchestrator)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session for orchestrator test"
    exit 1
fi

# Start Claude WITHOUT any AGENT_ROLE (simulates orchestrator)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "export WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter

pass "Started Claude with no AGENT_ROLE (orchestrator)"

echo "Waiting for Claude to initialize..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started (prompt visible)"
else
    fail "Claude prompt not visible"
fi

# Send Task tool request
echo "Sending request to use Task tool..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Right now, immediately invoke the Task tool with subagent_type=Explore to explore this codebase. Do not ask for clarification, just invoke the tool."
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter

echo "Waiting for Claude to process (60 seconds)..."
sleep 60

# Capture output
ORCH_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

echo ""
echo "Debug - Claude response (last 30 lines):"
echo "$ORCH_OUTPUT" | tail -30
echo ""

# Verify orchestrator was NOT blocked (should see Task tool usage or normal response)
if echo "$ORCH_OUTPUT" | grep -qi "TASK SUB-AGENT BLOCKED\|contact your PM\|delegate work"; then
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
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    exit 0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    exit 1
fi
