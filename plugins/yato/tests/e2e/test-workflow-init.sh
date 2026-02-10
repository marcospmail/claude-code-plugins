#!/bin/bash
# test-workflow-init.sh
#
# E2E Test: Workflow Initialization
#
# Verifies that workflow initialization creates the correct structure:
# - .workflow/001-slug-name/ folder
# - status.yml with correct fields
# - agents.yml with PM entry
# - agents/pm/ directory with identity and instructions
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All workflow creation goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="workflow-init"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-wf-init-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Workflow Initialization"
echo "======================================================================"
echo ""

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

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup
# ============================================================
echo "Phase 1: Creating test project..."

mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# Initialize git so init-workflow.sh works
cd "$TEST_DIR" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

echo "  - Project: $TEST_DIR"

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start
echo "  - Waiting for Claude to start..."
sleep 8

# Handle trust prompt
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  - Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  - No trust prompt found, continuing..."
    sleep 5
fi

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Initialize workflow through Claude
# ============================================================
echo "Phase 2: Running init-workflow.sh through Claude..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Add user authentication feature'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Debug: show what Claude did
echo "  Debug - After workflow init:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -30 | tail -15
echo ""

echo "  - Workflow initialized"
echo ""

# ============================================================
# PHASE 3: Verify structure
# ============================================================
echo "Phase 3: Verifying workflow structure..."
echo ""

# Find workflow folder
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)

if [[ -n "$WORKFLOW_NAME" ]]; then
    pass "Workflow folder created"
    echo "       Workflow name: $WORKFLOW_NAME"
else
    fail "No workflow folder found (expected 001-xxx pattern)"
fi

WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

# Test folder naming (should be 001-add-user-authentication-...)
if [[ "$WORKFLOW_NAME" == 001-* ]]; then
    pass "Workflow folder starts with 001-"
else
    fail "Workflow folder should start with '001-', got: $WORKFLOW_NAME"
fi

# Test status.yml exists
echo ""
echo "Testing status.yml..."
STATUS_FILE="$WORKFLOW_PATH/status.yml"
if [[ -f "$STATUS_FILE" ]]; then
    pass "status.yml exists"
else
    fail "status.yml not found"
fi

# Test status.yml fields
if grep -q "^status:" "$STATUS_FILE" 2>/dev/null; then
    pass "status.yml has 'status' field"
else
    fail "status.yml missing 'status' field"
fi

if grep -q "^title:" "$STATUS_FILE" 2>/dev/null; then
    pass "status.yml has 'title' field"
else
    fail "status.yml missing 'title' field"
fi

if grep -q "^checkin_interval_minutes:" "$STATUS_FILE" 2>/dev/null; then
    pass "status.yml has 'checkin_interval_minutes' field"
else
    fail "status.yml missing 'checkin_interval_minutes' field"
fi

# Test agents.yml
echo ""
echo "Testing agents.yml..."
AGENTS_YML="$WORKFLOW_PATH/agents.yml"
if [[ -f "$AGENTS_YML" ]]; then
    pass "agents.yml exists"
else
    fail "agents.yml not found"
fi

if grep -q "^pm:" "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml has PM entry"
else
    fail "agents.yml missing PM entry"
fi

if grep -q "window: 0" "$AGENTS_YML" 2>/dev/null; then
    pass "PM window is 0"
else
    fail "PM should be at window 0"
fi

if grep -q "pane: 1" "$AGENTS_YML" 2>/dev/null; then
    pass "PM pane is 1"
else
    fail "PM should be at pane 1"
fi

# Test PM agent folder
echo ""
echo "Testing PM agent folder..."
PM_DIR="$WORKFLOW_PATH/agents/pm"
if [[ -d "$PM_DIR" ]]; then
    pass "agents/pm/ directory exists"
else
    fail "agents/pm/ directory not found"
fi

if [[ -f "$PM_DIR/identity.yml" ]]; then
    pass "PM identity.yml exists"
else
    fail "PM identity.yml not found"
fi

if [[ -f "$PM_DIR/instructions.md" ]]; then
    pass "PM instructions.md exists"
else
    fail "PM instructions.md not found"
fi

# Test PM identity has agents_registry reference
if grep -q "agents_registry:" "$PM_DIR/identity.yml" 2>/dev/null; then
    pass "PM identity.yml references agents_registry"
else
    fail "PM identity.yml should reference agents_registry"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    EXIT_CODE=0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    EXIT_CODE=1
fi
echo "======================================================================"
echo ""

exit $EXIT_CODE
