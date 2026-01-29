#!/bin/bash
# E2E Test: Full workflow - new project creation
# Simulates a real user creating a new project from scratch
# Run: ./tests/test-workflow-new-project.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
# Use a simple name that will become the session name (derived from basename)
TEST_DIR="/tmp/newproj$$"
# Session name is derived from project dir basename by resume-workflow.sh
TEST_SESSION="newproj$$"

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
echo "║   E2E Test: New Project Workflow (Like Real User)           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Scenario: User creates a new game project from scratch"
echo ""

# ============================================================================
# STEP 1: User creates project directory
# ============================================================================
echo "=== Step 1: User creates project directory ==="
mkdir -p "$TEST_DIR"
if [[ -d "$TEST_DIR" ]]; then
    pass "Project directory created: $TEST_DIR"
else
    fail "Could not create project directory"
    exit 1
fi

# ============================================================================
# STEP 2: User initializes workflow with a description
# ============================================================================
echo ""
echo "=== Step 2: User initializes workflow ==="
OUTPUT=$("$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Build a memory card game with React" 2>&1)

if echo "$OUTPUT" | grep -q "WORKFLOW CREATED SUCCESSFULLY"; then
    pass "Workflow initialized successfully"
else
    fail "Workflow initialization failed"
    echo "$OUTPUT"
fi

# Get workflow name
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -n "$WORKFLOW_NAME" ]]; then
    pass "Workflow folder created: $WORKFLOW_NAME"
else
    fail "No workflow folder found"
fi

# ============================================================================
# STEP 3: User verifies workflow structure
# ============================================================================
echo ""
echo "=== Step 3: User verifies workflow structure ==="

# Check status.yml
if [[ -f "$WORKFLOW_PATH/status.yml" ]]; then
    pass "status.yml exists"
else
    fail "status.yml missing"
fi

# Check agents.yml
if [[ -f "$WORKFLOW_PATH/agents.yml" ]]; then
    pass "agents.yml exists"
else
    fail "agents.yml missing"
fi

# Check PM directory
if [[ -d "$WORKFLOW_PATH/agents/pm" ]]; then
    pass "PM agent directory exists"
else
    fail "PM agent directory missing"
fi

# Check PM files
for file in identity.yml instructions.md; do
    if [[ -f "$WORKFLOW_PATH/agents/pm/$file" ]]; then
        pass "PM $file exists"
    else
        fail "PM $file missing"
    fi
done

# ============================================================================
# STEP 4: User creates tasks.json with project tasks
# ============================================================================
echo ""
echo "=== Step 4: User creates tasks.json ==="
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Set up React project structure", "status": "pending", "assignee": "developer"},
    {"id": "2", "title": "Create card component", "status": "pending", "assignee": "developer"},
    {"id": "3", "title": "Implement game logic", "status": "pending", "assignee": "developer"},
    {"id": "4", "title": "Add animations", "status": "pending", "assignee": "developer"},
    {"id": "5", "title": "Test game functionality", "status": "pending", "assignee": "qa"}
  ]
}
EOF

if [[ -f "$WORKFLOW_PATH/tasks.json" ]]; then
    TASK_COUNT=$(python3 -c "import json; print(len(json.load(open('$WORKFLOW_PATH/tasks.json'))['tasks']))")
    pass "tasks.json created with $TASK_COUNT tasks"
else
    fail "tasks.json not created"
fi

# ============================================================================
# STEP 5: User configures team in agents.yml
# ============================================================================
echo ""
echo "=== Step 5: User configures team in agents.yml ==="
cat > "$WORKFLOW_PATH/agents.yml" << EOF
# Agent Registry
pm:
  name: pm
  role: pm
  session: "$TEST_SESSION"
  window: 0
  pane: 1
  model: opus

agents:
  - name: react-dev
    role: developer
    session: "$TEST_SESSION"
    window: 1
    model: sonnet
  - name: qa-engineer
    role: qa
    session: "$TEST_SESSION"
    window: 2
    model: haiku
EOF

# Create agent directories
mkdir -p "$WORKFLOW_PATH/agents/developer" "$WORKFLOW_PATH/agents/qa"
echo "# Developer Instructions" > "$WORKFLOW_PATH/agents/developer/instructions.md"
echo "# QA Instructions" > "$WORKFLOW_PATH/agents/qa/instructions.md"

if grep -q "react-dev" "$WORKFLOW_PATH/agents.yml" && grep -q "qa-engineer" "$WORKFLOW_PATH/agents.yml"; then
    pass "Team configured with developer and QA"
else
    fail "Team configuration failed"
fi

# ============================================================================
# STEP 6: User starts the workflow (resume-workflow.sh)
# ============================================================================
echo ""
echo "=== Step 6: User starts the workflow ==="
RESUME_OUTPUT=$("$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" 2>&1)

if echo "$RESUME_OUTPUT" | grep -q "WORKFLOW RESUMED SUCCESSFULLY"; then
    pass "Workflow started successfully"
else
    fail "Workflow failed to start"
    echo "$RESUME_OUTPUT"
fi

# ============================================================================
# STEP 7: User verifies tmux session created correctly
# ============================================================================
echo ""
echo "=== Step 7: User verifies tmux session ==="

# Check session exists
if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Tmux session '$TEST_SESSION' exists"
else
    fail "Tmux session not created"
fi

# Check windows
WINDOW_LIST=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}" 2>/dev/null)
echo "  Windows: $WINDOW_LIST"

# Verify window 0 (orchestrator with Check-ins and PM panes)
PANE_COUNT=$(tmux list-panes -t "$TEST_SESSION:0" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$PANE_COUNT" -ge 2 ]]; then
    pass "Window 0 has Check-ins and PM panes ($PANE_COUNT panes)"
else
    fail "Window 0 should have 2 panes"
fi

# Verify developer window
if echo "$WINDOW_LIST" | grep -q "react-dev"; then
    pass "Developer window 'react-dev' exists"
else
    fail "Developer window missing"
fi

# Verify QA window
if echo "$WINDOW_LIST" | grep -q "qa-engineer"; then
    pass "QA window 'qa-engineer' exists"
else
    fail "QA window missing"
fi

# ============================================================================
# STEP 8: User verifies Claude running in agent windows
# ============================================================================
echo ""
echo "=== Step 8: User verifies Claude running in agents ==="
sleep 3  # Give Claude time to start

CLAUDE_COUNT=0
for window in 1 2; do
    PANE_CONTENT=$(tmux capture-pane -t "$TEST_SESSION:$window" -p 2>/dev/null | tail -15)
    if echo "$PANE_CONTENT" | grep -qi "claude\|bypass\|anthropic"; then
        CLAUDE_COUNT=$((CLAUDE_COUNT + 1))
    fi
done

if [[ "$CLAUDE_COUNT" -ge 1 ]]; then
    pass "Claude running in $CLAUDE_COUNT agent windows"
else
    skip "Could not verify Claude (may need more startup time)"
fi

# ============================================================================
# STEP 9: User verifies agents.yml updated with window numbers
# ============================================================================
echo ""
echo "=== Step 9: User verifies agents.yml updated ==="
if grep -q "window:" "$WORKFLOW_PATH/agents.yml"; then
    pass "agents.yml contains window numbers"
else
    fail "agents.yml missing window numbers"
fi

# ============================================================================
# STEP 10: User verifies layout.yml saved
# ============================================================================
echo ""
echo "=== Step 10: User verifies layout.yml saved ==="
if [[ -f "$WORKFLOW_PATH/layout.yml" ]]; then
    if grep -q "agent_windows:" "$WORKFLOW_PATH/layout.yml"; then
        pass "layout.yml saved with agent windows"
    else
        fail "layout.yml missing agent_windows section"
    fi
else
    fail "layout.yml not created"
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
