#!/bin/bash
# Test create-agent.sh window-per-agent functionality
# Run: ./tests/test-create-agent.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-create-agent-$$"
TEST_SESSION="test-agent-$$"

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
echo "║          Testing create-agent.sh                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"

# Initialize workflow for agent creation
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test Agent Creation" > /dev/null 2>&1

# Get the workflow name
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)

# Create current file for workflow discovery (since we're not inside tmux)
echo "$WORKFLOW_NAME" > "$TEST_DIR/.workflow/current"

# Create tmux session with WORKFLOW_NAME env var set
echo "Creating test tmux session: $TEST_SESSION"
tmux new-session -d -s "$TEST_SESSION" -c "$TEST_DIR"
tmux setenv -t "$TEST_SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"

# Test 1: Create developer agent
echo ""
echo "=== Test 1: Create developer agent ==="
OUTPUT=$("$PROJECT_ROOT/bin/create-agent.sh" "$TEST_SESSION" developer \
    -p "$TEST_DIR" \
    --pm-window "$TEST_SESSION:0" \
    --no-start \
    --no-brief 2>&1)

if echo "$OUTPUT" | grep -q "Agent created successfully"; then
    pass "Developer agent created"
else
    fail "Failed to create developer agent"
    echo "$OUTPUT"
fi

# Test 2: Verify agent window was created
echo ""
echo "=== Test 2: Verify agent window created ==="
WINDOW_COUNT=$(tmux list-windows -t "$TEST_SESSION" | wc -l | tr -d ' ')
if [[ "$WINDOW_COUNT" -ge 2 ]]; then
    pass "Agent window created (now have $WINDOW_COUNT windows)"
else
    fail "Agent window not created"
fi

# Test 3: Verify window name
echo ""
echo "=== Test 3: Verify window name ==="
if tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" | grep -qi "developer"; then
    pass "Developer window name is correct"
else
    fail "Developer window name incorrect"
    tmux list-windows -t "$TEST_SESSION" -F "#{window_name}"
fi

# Test 4: Verify agent directory created
echo ""
echo "=== Test 4: Verify agent directory created ==="
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
AGENT_DIR="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents/developer"
if [[ -d "$AGENT_DIR" ]]; then
    pass "Agent directory created: $AGENT_DIR"
else
    fail "Agent directory not created"
fi

# Test 5: Verify identity.yml created
echo ""
echo "=== Test 5: Verify identity.yml created ==="
if [[ -f "$AGENT_DIR/identity.yml" ]]; then
    pass "identity.yml created"
else
    fail "identity.yml not created"
fi

# Test 6: Verify identity.yml has correct role
echo ""
echo "=== Test 6: Verify identity.yml has correct role ==="
if grep -q "role: developer" "$AGENT_DIR/identity.yml"; then
    pass "identity.yml has correct role"
else
    fail "identity.yml has incorrect role"
fi

# Test 7: Verify identity.yml has window number
echo ""
echo "=== Test 7: Verify identity.yml has window number ==="
if grep -q "window:" "$AGENT_DIR/identity.yml"; then
    pass "identity.yml has window number"
else
    fail "identity.yml missing window number"
fi

# Test 8: Verify instructions.md created
echo ""
echo "=== Test 8: Verify instructions.md created ==="
if [[ -f "$AGENT_DIR/instructions.md" ]]; then
    pass "instructions.md created"
else
    fail "instructions.md not created"
fi

# Test 9: Verify CLAUDE.md created
echo ""
echo "=== Test 9: Verify CLAUDE.md created ==="
if [[ -f "$AGENT_DIR/CLAUDE.md" ]]; then
    pass "CLAUDE.md created"
else
    fail "CLAUDE.md not created"
fi

# Test 10: Create QA agent with different model
echo ""
echo "=== Test 10: Create QA agent with haiku model ==="
OUTPUT_QA=$("$PROJECT_ROOT/bin/create-agent.sh" "$TEST_SESSION" qa \
    -p "$TEST_DIR" \
    -m haiku \
    --pm-window "$TEST_SESSION:0" \
    --no-start \
    --no-brief 2>&1)

if echo "$OUTPUT_QA" | grep -q "Agent created successfully"; then
    pass "QA agent created with haiku model"
else
    fail "Failed to create QA agent"
fi

# Test 11: Verify QA agent has haiku model in identity.yml
echo ""
echo "=== Test 11: Verify QA model is haiku ==="
QA_DIR="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents/qa"
if grep -q "model: haiku" "$QA_DIR/identity.yml"; then
    pass "QA agent has haiku model"
else
    fail "QA agent model incorrect"
fi

# Test 12: Verify QA can_modify_code is false
echo ""
echo "=== Test 12: Verify QA can_modify_code is false ==="
if grep -q "can_modify_code: false" "$QA_DIR/identity.yml"; then
    pass "QA can_modify_code is false"
else
    fail "QA can_modify_code should be false"
fi

# Test 13: Verify developer can_modify_code is true
echo ""
echo "=== Test 13: Verify developer can_modify_code is true ==="
if grep -q "can_modify_code: true" "$AGENT_DIR/identity.yml"; then
    pass "Developer can_modify_code is true"
else
    fail "Developer can_modify_code should be true"
fi

# Test 14: Create custom-named agent
echo ""
echo "=== Test 14: Create agent with custom name ==="
OUTPUT_CUSTOM=$("$PROJECT_ROOT/bin/create-agent.sh" "$TEST_SESSION" devops \
    -p "$TEST_DIR" \
    -n "InfraAgent" \
    --no-start \
    --no-brief 2>&1)

if tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" | grep -q "InfraAgent"; then
    pass "Custom-named agent window created"
else
    fail "Custom name not applied to window"
fi

# Test 15: Verify multiple windows (should have 4 now: initial + 3 agents)
echo ""
echo "=== Test 15: Verify multiple agent windows ==="
FINAL_WINDOW_COUNT=$(tmux list-windows -t "$TEST_SESSION" | wc -l | tr -d ' ')
if [[ "$FINAL_WINDOW_COUNT" -ge 4 ]]; then
    pass "All agent windows created ($FINAL_WINDOW_COUNT windows)"
else
    fail "Expected at least 4 windows, got $FINAL_WINDOW_COUNT"
fi

# Test 16: Missing session error
echo ""
echo "=== Test 16: Missing session shows error ==="
OUTPUT_ERR=$("$PROJECT_ROOT/bin/create-agent.sh" "nonexistent-session" developer 2>&1 || true)
if echo "$OUTPUT_ERR" | grep -q "does not exist"; then
    pass "Missing session shows error"
else
    fail "Missing session should show error"
fi

# Test 17: Help option works
echo ""
echo "=== Test 17: Help option works ==="
OUTPUT_HELP=$("$PROJECT_ROOT/bin/create-agent.sh" --help 2>&1)
if echo "$OUTPUT_HELP" | grep -q "Usage:"; then
    pass "Help option displays usage"
else
    fail "Help option should show usage"
fi

# Test 18: Verify each agent is in separate window (window-per-agent)
echo ""
echo "=== Test 18: Verify window-per-agent architecture ==="
WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}")
echo "  Windows: $WINDOWS"
# Count unique window indices
UNIQUE_WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}" | sort -u | wc -l | tr -d ' ')
TOTAL_WINDOWS=$(tmux list-windows -t "$TEST_SESSION" | wc -l | tr -d ' ')
if [[ "$UNIQUE_WINDOWS" -eq "$TOTAL_WINDOWS" ]]; then
    pass "Each agent is in a separate window"
else
    fail "Window-per-agent architecture violated"
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
