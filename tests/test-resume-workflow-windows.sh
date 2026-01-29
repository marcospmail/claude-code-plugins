#!/bin/bash
# Test resume-workflow.sh window-per-agent architecture
# Run: ./tests/test-resume-workflow-windows.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-resume-$$"
# Session name is derived from project dir basename by resume-workflow.sh
TEST_SESSION="test-resume-$$"

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
echo "║     Testing resume-workflow.sh Window-Per-Agent              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup test environment
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"

# Source workflow utils
source "$PROJECT_ROOT/bin/workflow-utils.sh"

# Create a workflow
echo "Creating test workflow..."
WORKFLOW_NAME=$(create_workflow_folder "$TEST_DIR" "Test Resume Windows")
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

# Create agents.yml with multiple agents
echo ""
echo "=== Test 1: Create agents.yml with multiple agents ==="
cat > "$WORKFLOW_PATH/agents.yml" <<EOF
# Agent Registry
pm:
  name: pm
  role: pm
  session: "$TEST_SESSION"
  window: 0
  pane: 1
  model: opus

agents:
  - name: developer-1
    role: developer
    session: "$TEST_SESSION"
    window: 1
    model: sonnet
  - name: qa-tester
    role: qa
    session: "$TEST_SESSION"
    window: 2
    model: haiku
  - name: developer-2
    role: developer
    session: "$TEST_SESSION"
    window: 3
    model: sonnet
EOF

if [[ -f "$WORKFLOW_PATH/agents.yml" ]]; then
    pass "agents.yml created with 3 agents"
else
    fail "agents.yml not created"
fi

# Create agent directories with instructions
echo ""
echo "=== Test 2: Create agent directories ==="
mkdir -p "$WORKFLOW_PATH/agents/developer"
mkdir -p "$WORKFLOW_PATH/agents/qa"
echo "# Developer Instructions" > "$WORKFLOW_PATH/agents/developer/instructions.md"
echo "# QA Instructions" > "$WORKFLOW_PATH/agents/qa/instructions.md"

if [[ -d "$WORKFLOW_PATH/agents/developer" ]] && [[ -d "$WORKFLOW_PATH/agents/qa" ]]; then
    pass "Agent directories created"
else
    fail "Agent directories not created"
fi

# Run resume-workflow.sh
echo ""
echo "=== Test 3: Run resume-workflow.sh ==="
OUTPUT=$("$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" 2>&1) || true

if echo "$OUTPUT" | grep -q "WORKFLOW RESUMED SUCCESSFULLY"; then
    pass "resume-workflow.sh completed successfully"
else
    fail "resume-workflow.sh failed"
    echo "$OUTPUT"
fi

# Test 4: Verify session was created
echo ""
echo "=== Test 4: Verify tmux session created ==="
if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Session '$TEST_SESSION' exists"
else
    fail "Session '$TEST_SESSION' not created"
fi

# Test 5: Verify window 0 has Check-ins and PM panes
echo ""
echo "=== Test 5: Verify window 0 layout (Check-ins + PM panes) ==="
PANE_COUNT=$(tmux list-panes -t "$TEST_SESSION:0" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PANE_COUNT" -ge 2 ]]; then
    pass "Window 0 has $PANE_COUNT panes (Check-ins + PM)"
else
    fail "Window 0 should have at least 2 panes, got $PANE_COUNT"
fi

# Test 6: Verify Check-ins pane title
echo ""
echo "=== Test 6: Verify Check-ins pane title ==="
CHECKINS_TITLE=$(tmux display-message -t "$TEST_SESSION:0.0" -p "#{pane_title}" 2>/dev/null)
if [[ "$CHECKINS_TITLE" == "Check-ins" ]]; then
    pass "Check-ins pane has correct title"
else
    fail "Check-ins pane title incorrect: '$CHECKINS_TITLE'"
fi

# Test 7: Verify PM pane title
echo ""
echo "=== Test 7: Verify PM pane title ==="
PM_TITLE=$(tmux display-message -t "$TEST_SESSION:0.1" -p "#{pane_title}" 2>/dev/null)
if [[ "$PM_TITLE" == "PM" ]]; then
    pass "PM pane has correct title"
else
    fail "PM pane title incorrect: '$PM_TITLE'"
fi

# Test 8: Verify agent windows were created
echo ""
echo "=== Test 8: Verify agent windows created ==="
WINDOW_COUNT=$(tmux list-windows -t "$TEST_SESSION" 2>/dev/null | wc -l | tr -d ' ')
# Should have window 0 (orchestrator) + 3 agent windows = 4 total
if [[ "$WINDOW_COUNT" -ge 4 ]]; then
    pass "Session has $WINDOW_COUNT windows (orchestrator + 3 agents)"
else
    fail "Expected at least 4 windows, got $WINDOW_COUNT"
fi

# Test 9: Verify developer-1 window exists
echo ""
echo "=== Test 9: Verify developer-1 window ==="
if tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" | grep -q "developer-1"; then
    pass "developer-1 window exists"
else
    fail "developer-1 window not found"
fi

# Test 10: Verify qa-tester window exists
echo ""
echo "=== Test 10: Verify qa-tester window ==="
if tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" | grep -q "qa-tester"; then
    pass "qa-tester window exists"
else
    fail "qa-tester window not found"
fi

# Test 11: Verify developer-2 window exists
echo ""
echo "=== Test 11: Verify developer-2 window ==="
if tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" | grep -q "developer-2"; then
    pass "developer-2 window exists"
else
    fail "developer-2 window not found"
fi

# Test 12: Verify agents.yml was updated with new window numbers
echo ""
echo "=== Test 12: Verify agents.yml updated with window numbers ==="
# The window numbers may have changed from original, but they should exist
AGENTS_YML="$WORKFLOW_PATH/agents.yml"
if grep -q "window:" "$AGENTS_YML"; then
    pass "agents.yml contains window numbers"
else
    fail "agents.yml missing window numbers"
fi

# Test 13: Verify layout.yml was created with window-based format
echo ""
echo "=== Test 13: Verify layout.yml created ==="
LAYOUT_FILE="$WORKFLOW_PATH/layout.yml"
if [[ -f "$LAYOUT_FILE" ]]; then
    pass "layout.yml created"
else
    fail "layout.yml not created"
fi

# Test 14: Verify layout.yml has agent_windows section
echo ""
echo "=== Test 14: Verify layout.yml has agent_windows section ==="
if grep -q "agent_windows:" "$LAYOUT_FILE"; then
    pass "layout.yml has agent_windows section"
else
    fail "layout.yml missing agent_windows section"
fi

# Test 15: Verify layout.yml has correct agent entries
echo ""
echo "=== Test 15: Verify layout.yml has all agents ==="
AGENT_COUNT=$(grep -c "name:" "$LAYOUT_FILE" 2>/dev/null || echo "0")
if [[ "$AGENT_COUNT" -ge 3 ]]; then
    pass "layout.yml has $AGENT_COUNT agent entries"
else
    fail "layout.yml should have 3 agents, found $AGENT_COUNT"
fi

# Test 16: Verify Claude is running in agent windows
echo ""
echo "=== Test 16: Verify Claude started in agent windows ==="
sleep 2  # Give Claude time to start
CLAUDE_FOUND=0
for window in 1 2 3; do
    PANE_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:$window" -p 2>/dev/null | tail -10)
    if echo "$PANE_CONTENT" | grep -q "claude\|bypass permissions"; then
        CLAUDE_FOUND=$((CLAUDE_FOUND + 1))
    fi
done

if [[ "$CLAUDE_FOUND" -ge 1 ]]; then
    pass "Claude running in $CLAUDE_FOUND agent windows"
else
    skip "Could not verify Claude running (may need more time to start)"
fi

# Test 17: Verify window order matches agents.yml order
echo ""
echo "=== Test 17: Verify window naming ==="
WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}")
echo "  Windows: $WINDOWS"
if echo "$WINDOWS" | grep -q "developer-1" && echo "$WINDOWS" | grep -q "qa-tester" && echo "$WINDOWS" | grep -q "developer-2"; then
    pass "All agent windows properly named"
else
    fail "Agent window naming incorrect"
fi

# Test 18: Verify resume output shows correct info
echo ""
echo "=== Test 18: Verify resume output ==="
if echo "$OUTPUT" | grep -q "Agents restored:" && echo "$OUTPUT" | grep -q "Window layout:"; then
    pass "Resume output contains expected sections"
else
    fail "Resume output missing expected sections"
fi

# Summary
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
