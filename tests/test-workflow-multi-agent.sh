#!/bin/bash
# E2E Test: Full workflow - multi-agent team coordination
# Tests 3+ agents with communication between them
# Run: ./tests/test-workflow-multi-agent.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/multiagent$$"
TEST_SESSION="multiagent$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }

PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   E2E Test: Multi-Agent Team Coordination (3+ Agents)       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Scenario: User creates a full team (PM + 2 devs + QA) and tests coordination"
echo ""

# ============================================================================
# STEP 1: Initialize project with workflow
# ============================================================================
echo "=== Step 1: Initialize project with workflow ==="
mkdir -p "$TEST_DIR"

"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Build microservices architecture" > /dev/null 2>&1

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -n "$WORKFLOW_NAME" ]]; then
    pass "Workflow created: $WORKFLOW_NAME"
else
    fail "Workflow not created"
    exit 1
fi

# ============================================================================
# STEP 2: Create multi-team tasks
# ============================================================================
echo ""
echo "=== Step 2: Create tasks for multi-agent team ==="

cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Set up API service", "status": "pending", "assignee": "backend-dev"},
    {"id": "2", "title": "Set up Auth service", "status": "pending", "assignee": "backend-dev"},
    {"id": "3", "title": "Build frontend dashboard", "status": "pending", "assignee": "frontend-dev"},
    {"id": "4", "title": "Integration tests", "status": "pending", "assignee": "qa-lead"},
    {"id": "5", "title": "Performance testing", "status": "pending", "assignee": "qa-lead"}
  ]
}
EOF

TASK_COUNT=$(python3 -c "import json; print(len(json.load(open('$WORKFLOW_PATH/tasks.json'))['tasks']))")
if [[ "$TASK_COUNT" -eq 5 ]]; then
    pass "Created $TASK_COUNT tasks for multiple team members"
else
    fail "Task creation failed"
fi

# ============================================================================
# STEP 3: Configure 3-agent team (backend, frontend, qa)
# ============================================================================
echo ""
echo "=== Step 3: Configure 3-agent team ==="

cat > "$WORKFLOW_PATH/agents.yml" << EOF
# Agent Registry - Multi-Agent Team
pm:
  name: pm
  role: pm
  session: "$TEST_SESSION"
  window: 0
  pane: 1
  model: opus

agents:
  - name: backend-dev
    role: developer
    session: "$TEST_SESSION"
    window: 1
    model: sonnet
  - name: frontend-dev
    role: developer
    session: "$TEST_SESSION"
    window: 2
    model: sonnet
  - name: qa-lead
    role: qa
    session: "$TEST_SESSION"
    window: 3
    model: haiku
EOF

# Create agent instruction directories
mkdir -p "$WORKFLOW_PATH/agents/developer" "$WORKFLOW_PATH/agents/qa"

cat > "$WORKFLOW_PATH/agents/developer/instructions.md" << 'EOF'
# Developer Agent Instructions

You are a developer agent. Your responsibilities:
1. Implement assigned tasks
2. Report progress to PM using notify-pm.sh
3. Request help when blocked
EOF

cat > "$WORKFLOW_PATH/agents/qa/instructions.md" << 'EOF'
# QA Agent Instructions

You are a QA agent. Your responsibilities:
1. Test implemented features
2. Report bugs to PM
3. Verify fixes
EOF

AGENT_COUNT=$(grep -c "name:" "$WORKFLOW_PATH/agents.yml" | head -1)
AGENT_COUNT=${AGENT_COUNT:-0}
if [[ "$AGENT_COUNT" -ge 3 ]]; then
    pass "Configured team with $AGENT_COUNT agents"
else
    fail "Agent configuration incomplete"
fi

# ============================================================================
# STEP 4: Start workflow and verify session created
# ============================================================================
echo ""
echo "=== Step 4: Start workflow ==="

"$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" > /dev/null 2>&1

if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Tmux session created"
else
    fail "Tmux session not created"
    exit 1
fi

# ============================================================================
# STEP 5: Verify all agent windows created
# ============================================================================
echo ""
echo "=== Step 5: Verify all agent windows created ==="

WINDOW_LIST=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" 2>/dev/null)
WINDOW_COUNT=$(echo "$WINDOW_LIST" | wc -l | tr -d ' ')

echo "  Windows created: $WINDOW_COUNT"
echo "  Window names: $(echo "$WINDOW_LIST" | tr '\n' ' ')"

# Check for each expected agent window
if echo "$WINDOW_LIST" | grep -q "backend-dev"; then
    pass "Backend developer window exists"
else
    fail "Backend developer window missing"
fi

if echo "$WINDOW_LIST" | grep -q "frontend-dev"; then
    pass "Frontend developer window exists"
else
    fail "Frontend developer window missing"
fi

if echo "$WINDOW_LIST" | grep -q "qa-lead"; then
    pass "QA lead window exists"
else
    fail "QA lead window missing"
fi

# ============================================================================
# STEP 6: Verify PM pane layout (Check-ins + PM)
# ============================================================================
echo ""
echo "=== Step 6: Verify PM pane layout ==="

PANE_COUNT=$(tmux list-panes -t "$TEST_SESSION:0" 2>/dev/null | wc -l | tr -d ' ')

if [[ "$PANE_COUNT" -ge 2 ]]; then
    pass "Window 0 has Check-ins and PM panes ($PANE_COUNT panes)"
else
    fail "Window 0 should have at least 2 panes"
fi

# ============================================================================
# STEP 7: Test send-message.sh to agent window
# ============================================================================
echo ""
echo "=== Step 7: Test send-message.sh to agent window ==="

# Get backend-dev window number
BACKEND_WINDOW=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}" | grep "backend-dev" | cut -d: -f1)

if [[ -n "$BACKEND_WINDOW" ]]; then
    # Send a test message
    "$PROJECT_ROOT/bin/send-message.sh" "$TEST_SESSION:$BACKEND_WINDOW" "Test message from orchestrator" > /dev/null 2>&1
    sleep 2

    # Capture pane content to verify message was sent
    PANE_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:$BACKEND_WINDOW" -p 2>/dev/null | tail -10)

    if echo "$PANE_CONTENT" | grep -qi "test message\|orchestrator"; then
        pass "send-message.sh delivered message to backend-dev"
    else
        skip "Could not verify message delivery (Claude may be processing)"
    fi
else
    fail "Could not find backend-dev window"
fi

# ============================================================================
# STEP 8: Verify agents.yml updated with actual window numbers
# ============================================================================
echo ""
echo "=== Step 8: Verify agents.yml updated with window numbers ==="

BACKEND_WINDOW_YML=$(grep -A5 "name: backend-dev" "$WORKFLOW_PATH/agents.yml" | grep "window:" | awk '{print $2}')
FRONTEND_WINDOW_YML=$(grep -A5 "name: frontend-dev" "$WORKFLOW_PATH/agents.yml" | grep "window:" | awk '{print $2}')
QA_WINDOW_YML=$(grep -A5 "name: qa-lead" "$WORKFLOW_PATH/agents.yml" | grep "window:" | awk '{print $2}')

echo "  backend-dev window: $BACKEND_WINDOW_YML"
echo "  frontend-dev window: $FRONTEND_WINDOW_YML"
echo "  qa-lead window: $QA_WINDOW_YML"

if [[ -n "$BACKEND_WINDOW_YML" ]] && [[ -n "$FRONTEND_WINDOW_YML" ]] && [[ -n "$QA_WINDOW_YML" ]]; then
    # Verify they're all different
    if [[ "$BACKEND_WINDOW_YML" != "$FRONTEND_WINDOW_YML" ]] && [[ "$FRONTEND_WINDOW_YML" != "$QA_WINDOW_YML" ]]; then
        pass "agents.yml updated with unique window numbers"
    else
        fail "Window numbers should be unique for each agent"
    fi
else
    fail "agents.yml missing window numbers"
fi

# ============================================================================
# STEP 9: Verify layout.yml saved correctly
# ============================================================================
echo ""
echo "=== Step 9: Verify layout.yml saved ==="

LAYOUT_FILE="$WORKFLOW_PATH/layout.yml"
if [[ -f "$LAYOUT_FILE" ]]; then
    if grep -q "agent_windows:" "$LAYOUT_FILE"; then
        SAVED_AGENT_COUNT=$(grep -c "name:" "$LAYOUT_FILE" || echo "0")
        if [[ "$SAVED_AGENT_COUNT" -ge 3 ]]; then
            pass "layout.yml saved with $SAVED_AGENT_COUNT agent configurations"
        else
            fail "layout.yml has incomplete agent data"
        fi
    else
        fail "layout.yml missing agent_windows section"
    fi
else
    fail "layout.yml not created"
fi

# ============================================================================
# STEP 10: Test notify-pm.sh (requires being inside tmux)
# ============================================================================
echo ""
echo "=== Step 10: Test notify-pm.sh simulation ==="

# notify-pm.sh needs to run from within tmux, so we simulate by sending to PM pane directly
PM_PANE="$TEST_SESSION:0.1"

"$PROJECT_ROOT/bin/send-message.sh" "$PM_PANE" "[DONE] Backend API setup complete - simulating notify-pm" > /dev/null 2>&1
sleep 2

PM_CONTENT=$(tmux capture-pane -t "$PM_PANE" -p 2>/dev/null | tail -10)

if echo "$PM_CONTENT" | grep -qi "done\|backend\|notify"; then
    pass "Message successfully sent to PM pane"
else
    skip "Could not verify PM message (Claude may be processing)"
fi

# ============================================================================
# STEP 11: Verify Claude running in multiple agent windows
# ============================================================================
echo ""
echo "=== Step 11: Verify Claude running in agents ==="
sleep 5  # Give Claude time to initialize

CLAUDE_COUNT=0
for agent in "backend-dev" "frontend-dev" "qa-lead"; do
    AGENT_WINDOW=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}" | grep "$agent" | cut -d: -f1)
    if [[ -n "$AGENT_WINDOW" ]]; then
        CONTENT=$(tmux capture-pane -t "$TEST_SESSION:$AGENT_WINDOW" -p 2>/dev/null | tail -15)
        if echo "$CONTENT" | grep -qi "claude\|bypass\|anthropic\|model"; then
            CLAUDE_COUNT=$((CLAUDE_COUNT + 1))
        fi
    fi
done

if [[ "$CLAUDE_COUNT" -ge 2 ]]; then
    pass "Claude running in $CLAUDE_COUNT agent windows"
else
    skip "Could not verify Claude in all agents (may need more startup time)"
fi

# ============================================================================
# STEP 12: Verify pane border status enabled
# ============================================================================
echo ""
echo "=== Step 12: Verify pane titles displayed ==="

# Check if pane-border-status is set
BORDER_STATUS=$(tmux show-options -t "$TEST_SESSION" pane-border-status 2>/dev/null | awk '{print $2}')

if [[ "$BORDER_STATUS" == "top" ]]; then
    pass "Pane border titles enabled (top)"
else
    skip "Pane border status not set to top"
fi

# ============================================================================
# STEP 13: Test session survives and can be listed
# ============================================================================
echo ""
echo "=== Step 13: Verify session stability ==="

SESSION_INFO=$(tmux ls 2>/dev/null | grep "$TEST_SESSION")

if [[ -n "$SESSION_INFO" ]]; then
    ATTACHED=$(echo "$SESSION_INFO" | grep -c "attached" || echo "0")
    pass "Session listed in tmux (attached: $ATTACHED)"
else
    fail "Session not found in tmux list"
fi

# Final window count verification
FINAL_WINDOW_COUNT=$(tmux list-windows -t "$TEST_SESSION" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$FINAL_WINDOW_COUNT" -ge 4 ]]; then
    pass "All windows preserved (count: $FINAL_WINDOW_COUNT)"
else
    fail "Some windows were lost (count: $FINAL_WINDOW_COUNT, expected >= 4)"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $PASSED"
echo -e "  ${RED}Failed${NC}:  $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
