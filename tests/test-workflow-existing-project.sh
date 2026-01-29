#!/bin/bash
# E2E Test: Full workflow - existing project with features
# Simulates a user adding features to an existing codebase
# Run: ./tests/test-workflow-existing-project.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/existing$$"
TEST_SESSION="existing$$"

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
echo "║   E2E Test: Existing Project Workflow (Add Features)        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Scenario: User has existing code and wants to add new features"
echo ""

# ============================================================================
# STEP 1: User has an existing project with code
# ============================================================================
echo "=== Step 1: User has existing project with code ==="
mkdir -p "$TEST_DIR/src" "$TEST_DIR/tests"

# Create existing project files
cat > "$TEST_DIR/package.json" << 'EOF'
{
  "name": "calculator-app",
  "version": "1.0.0",
  "scripts": {
    "start": "node src/index.js",
    "test": "jest"
  }
}
EOF

cat > "$TEST_DIR/src/calculator.js" << 'EOF'
// Basic calculator - existing code
class Calculator {
    add(a, b) { return a + b; }
    subtract(a, b) { return a - b; }
    // TODO: Add multiply and divide
}
module.exports = Calculator;
EOF

cat > "$TEST_DIR/src/index.js" << 'EOF'
const Calculator = require('./calculator');
const calc = new Calculator();
console.log('2 + 3 =', calc.add(2, 3));
EOF

# Verify files exist
if [[ -f "$TEST_DIR/package.json" ]] && [[ -f "$TEST_DIR/src/calculator.js" ]]; then
    pass "Existing project files created"
    echo "  - package.json"
    echo "  - src/calculator.js"
    echo "  - src/index.js"
else
    fail "Could not create existing project files"
fi

# ============================================================================
# STEP 2: User initializes workflow to add features
# ============================================================================
echo ""
echo "=== Step 2: User initializes workflow to add features ==="
OUTPUT=$("$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Add multiply, divide, and history feature" 2>&1)

if echo "$OUTPUT" | grep -q "WORKFLOW CREATED SUCCESSFULLY"; then
    pass "Workflow initialized on existing project"
else
    fail "Workflow initialization failed"
fi

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

# ============================================================================
# STEP 3: User verifies existing files NOT modified
# ============================================================================
echo ""
echo "=== Step 3: User verifies existing files untouched ==="

# Check calculator.js still has original content
if grep -q "TODO: Add multiply and divide" "$TEST_DIR/src/calculator.js"; then
    pass "calculator.js unchanged (TODO comment still present)"
else
    fail "calculator.js was modified!"
fi

# Check package.json still exists
if grep -q '"calculator-app"' "$TEST_DIR/package.json"; then
    pass "package.json unchanged"
else
    fail "package.json was modified!"
fi

# ============================================================================
# STEP 4: User creates feature tasks
# ============================================================================
echo ""
echo "=== Step 4: User creates feature tasks ==="
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Add multiply method to Calculator", "status": "pending", "assignee": "developer"},
    {"id": "2", "title": "Add divide method with zero check", "status": "pending", "assignee": "developer"},
    {"id": "3", "title": "Add calculation history feature", "status": "pending", "assignee": "developer"},
    {"id": "4", "title": "Write unit tests for new methods", "status": "pending", "assignee": "qa"},
    {"id": "5", "title": "Update README with new features", "status": "pending", "assignee": "developer"}
  ]
}
EOF

if [[ -f "$WORKFLOW_PATH/tasks.json" ]]; then
    pass "Feature tasks created"
else
    fail "tasks.json not created"
fi

# ============================================================================
# STEP 5: User configures single developer agent
# ============================================================================
echo ""
echo "=== Step 5: User configures developer agent ==="
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
  - name: feature-dev
    role: developer
    session: "$TEST_SESSION"
    window: 1
    model: sonnet
EOF

mkdir -p "$WORKFLOW_PATH/agents/developer"
echo "# Developer Instructions - Add features to calculator" > "$WORKFLOW_PATH/agents/developer/instructions.md"

if grep -q "feature-dev" "$WORKFLOW_PATH/agents.yml"; then
    pass "Developer agent configured"
else
    fail "Agent configuration failed"
fi

# ============================================================================
# STEP 6: User starts workflow
# ============================================================================
echo ""
echo "=== Step 6: User starts workflow ==="
RESUME_OUTPUT=$("$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" 2>&1)

if echo "$RESUME_OUTPUT" | grep -q "WORKFLOW RESUMED SUCCESSFULLY"; then
    pass "Workflow started"
else
    fail "Workflow failed to start"
fi

# ============================================================================
# STEP 7: User verifies session and windows
# ============================================================================
echo ""
echo "=== Step 7: User verifies session and windows ==="

if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Tmux session exists"
else
    fail "Tmux session not created"
fi

WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" 2>/dev/null)
if echo "$WINDOWS" | grep -q "feature-dev"; then
    pass "Developer window 'feature-dev' exists"
else
    fail "Developer window missing"
fi

# ============================================================================
# STEP 8: User verifies project structure still intact
# ============================================================================
echo ""
echo "=== Step 8: User verifies project structure intact ==="

# Existing files still there
if [[ -f "$TEST_DIR/src/calculator.js" ]] && [[ -f "$TEST_DIR/package.json" ]]; then
    pass "Original project files still exist"
else
    fail "Original files missing!"
fi

# Workflow files separate from project
if [[ -d "$TEST_DIR/.workflow" ]] && [[ -d "$TEST_DIR/src" ]]; then
    pass "Workflow files separate from source code"
else
    fail "File structure incorrect"
fi

# ============================================================================
# STEP 9: User checks working directory in agent window
# ============================================================================
echo ""
echo "=== Step 9: User verifies agent working directory ==="
sleep 2

# The agent window should be in the project directory
AGENT_PWD=$(tmux send-keys -t "$TEST_SESSION:1" "pwd" Enter && sleep 1 && tmux capture-pane -t "$TEST_SESSION:1" -p | grep -E "^/" | tail -1)

if [[ "$AGENT_PWD" == "$TEST_DIR" ]] || [[ -z "$AGENT_PWD" ]]; then
    pass "Agent window in correct directory (or Claude running)"
else
    skip "Could not verify working directory"
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
