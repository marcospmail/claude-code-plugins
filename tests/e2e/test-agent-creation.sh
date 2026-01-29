#!/bin/bash
# test-agent-creation.sh
#
# E2E Test: Agent Creation
#
# This test:
# 1. Sets up a project with a workflow
# 2. Spawns Claude to create a team (developer + qa)
# 3. Verifies with SHELL (not Claude):
#    - Tmux windows created correctly
#    - agents.yml has correct entries
#    - Smart naming applied (no numbers for single roles)
#    - Agent identity files exist

# Don't use set -e because we want to continue testing even if some checks fail
# set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-creation"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Creation                                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "  ✅ $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "  ❌ $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment (shell)
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -n "pm-checkins" -c "$TEST_DIR"

# Initialize workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test agent creation feature" > /dev/null 2>&1

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "$WORKFLOW_NAME"

echo "  - Project created at $TEST_DIR"
echo "  - Tmux session: $SESSION_NAME"
echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 2: Use Claude to create team (simulating real user)
# ============================================================
echo "Phase 2: Creating team via Claude..."

# Send command to tmux session to create team
tmux send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $PROJECT_ROOT/bin/create-team.sh $TEST_DIR developer qa" Enter

# Wait for team creation to complete
sleep 20

# Capture output for debugging
TEAM_OUTPUT=$(tmux capture-pane -t "$SESSION_NAME:0" -p)
echo "  - Team creation command executed"
echo ""

# ============================================================
# PHASE 3: Verify results with SHELL (not Claude)
# ============================================================
echo "Phase 3: Verifying results..."
echo ""

# Get workflow path (discover folder directly, no longer uses .workflow/current)
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"
AGENTS_YML="$WORKFLOW_PATH/agents.yml"

# Test 1: Check tmux windows exist
echo "Testing tmux windows..."
WINDOWS=$(tmux list-windows -t "$SESSION_NAME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WINDOWS" -ge 3 ]]; then
    pass "Created 3+ windows (PM + 2 agents)"
else
    fail "Expected 3+ windows, got $WINDOWS"
fi

# Test 2: Check window names
WINDOW_LIST=$(tmux list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" 2>/dev/null)
if echo "$WINDOW_LIST" | grep -q "1:developer"; then
    pass "Window 1 named 'developer'"
else
    fail "Window 1 should be named 'developer'"
fi

if echo "$WINDOW_LIST" | grep -q "2:qa"; then
    pass "Window 2 named 'qa'"
else
    fail "Window 2 should be named 'qa'"
fi

# Test 3: Check agents.yml exists
echo ""
echo "Testing agents.yml..."
if [[ -f "$AGENTS_YML" ]]; then
    pass "agents.yml file exists"
else
    fail "agents.yml file not found at $AGENTS_YML"
fi

# Test 4: Check agents.yml content - PM entry
if grep -q "^pm:" "$AGENTS_YML" 2>/dev/null; then
    pass "PM entry exists in agents.yml"
else
    fail "PM entry missing from agents.yml"
fi

# Test 5: Check agents.yml content - developer entry (no number = smart naming)
if grep -q "name: developer$" "$AGENTS_YML" 2>/dev/null; then
    pass "Developer agent has smart naming (no number suffix)"
else
    fail "Developer should be named 'developer' not 'developer-1'"
fi

# Test 6: Check agents.yml content - qa entry (no number = smart naming)
if grep -q "name: qa$" "$AGENTS_YML" 2>/dev/null; then
    pass "QA agent has smart naming (no number suffix)"
else
    fail "QA should be named 'qa' not 'qa-1'"
fi

# Test 7: Check developer window number in agents.yml
DEV_WINDOW=$(grep -A 3 "name: developer$" "$AGENTS_YML" 2>/dev/null | grep "window:" | awk '{print $2}')
if [[ "$DEV_WINDOW" == "1" ]]; then
    pass "Developer assigned to window 1"
else
    fail "Developer should be in window 1, got: $DEV_WINDOW"
fi

# Test 8: Check qa window number in agents.yml
QA_WINDOW=$(grep -A 3 "name: qa$" "$AGENTS_YML" 2>/dev/null | grep "window:" | awk '{print $2}')
if [[ "$QA_WINDOW" == "2" ]]; then
    pass "QA assigned to window 2"
else
    fail "QA should be in window 2, got: $QA_WINDOW"
fi

# Test 9: Check agent identity files exist
echo ""
echo "Testing agent identity files..."
if [[ -f "$WORKFLOW_PATH/agents/developer/identity.yml" ]]; then
    pass "Developer identity.yml exists"
else
    fail "Developer identity.yml not found"
fi

if [[ -f "$WORKFLOW_PATH/agents/qa/identity.yml" ]]; then
    pass "QA identity.yml exists"
else
    fail "QA identity.yml not found"
fi

# Test 10: Check instructions contain critical rule
echo ""
echo "Testing agent instructions..."
DEV_INSTRUCTIONS="$WORKFLOW_PATH/agents/developer/instructions.md"
if grep -q "NEVER COMMUNICATE DIRECTLY WITH THE USER" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    pass "Developer instructions contain 'never communicate with user' rule"
else
    fail "Developer instructions missing critical communication rule"
fi

QA_INSTRUCTIONS="$WORKFLOW_PATH/agents/qa/instructions.md"
if grep -q "NEVER COMMUNICATE DIRECTLY WITH THE USER" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA instructions contain 'never communicate with user' rule"
else
    fail "QA instructions missing critical communication rule"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                              ║"
    EXIT_CODE=0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                    ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
