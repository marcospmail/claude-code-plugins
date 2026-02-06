#!/bin/bash
# test-agent-creation.sh
#
# E2E Test: Yato Existing Project Skill
#
# This test verifies the /yato-existing-project skill works correctly:
# 1. Starts Claude in tmux with --dangerously-skip-permissions
# 2. Invokes /yato-existing-project skill
# 3. Verifies:
#    - Workflow folder created
#    - PM session exists with correct naming
#    - Status.yml created with initial request
#
# This tests PLUGIN INTEGRATION, not the full multi-minute PM workflow.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-creation"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"
PROJECT_SLUG="e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Yato Existing Project Skill                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Initial session: $SESSION_NAME"
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
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    # Kill any sessions matching the project pattern
    tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | grep "e2e-test-agent-creation" | cut -d: -f1 | xargs -I{} tmux -L "$TMUX_SOCKET" kill-session -t {} 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init -q
git config user.name "Test"
git config user.email "test@test.com"
echo "function test() { return true; }" > "$TEST_DIR/app.js"
git add -A && git commit -m "Initial" -q

echo "  - Project created at $TEST_DIR"
echo ""

# ============================================================
# PHASE 2: Start Claude and invoke /yato-existing-project
# ============================================================
echo "Phase 2: Starting Claude and invoking skill..."

# Create tmux session
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Start Claude with --dangerously-skip-permissions
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter

echo "  - Waiting for Claude to initialize (12 seconds)..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started"
else
    fail "Claude prompt not visible"
fi

# Invoke /yato-existing-project skill
echo "  - Invoking /yato-existing-project skill..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/yato-existing-project Test agent creation feature"
sleep 2
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter

echo "  - Waiting for skill to execute (120 seconds)..."
sleep 120

# Capture output for debugging
SKILL_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)
echo ""
echo "Debug - Skill output (last 20 lines):"
echo "$SKILL_OUTPUT" | tail -20
echo ""

# ============================================================
# PHASE 3: Verify results
# ============================================================
echo "Phase 3: Verifying results..."
echo ""

# Test 1: Check workflow folder was created
echo "Testing workflow folder creation..."
WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
if [[ -n "$WORKFLOW_DIR" ]] && [[ -d "$WORKFLOW_DIR" ]]; then
    WORKFLOW_NAME=$(basename "$WORKFLOW_DIR")
    pass "Workflow folder created: $WORKFLOW_NAME"
else
    fail "Workflow folder not created"
    WORKFLOW_NAME=""
fi

# Test 2: Check status.yml exists
if [[ -n "$WORKFLOW_NAME" ]] && [[ -f "$TEST_DIR/.workflow/$WORKFLOW_NAME/status.yml" ]]; then
    pass "status.yml exists"
else
    fail "status.yml not found"
fi

# Test 3: Check status.yml has session name
if [[ -n "$WORKFLOW_NAME" ]] && grep -q "session:" "$TEST_DIR/.workflow/$WORKFLOW_NAME/status.yml" 2>/dev/null; then
    pass "status.yml has session field"
else
    fail "status.yml missing session field"
fi

# Test 4: Check PM session was created (project_workflow format)
echo ""
echo "Testing PM session creation..."
# Look for session matching our test project (e2e-test-agent-creation-PID_001-xxx)
PM_SESSIONS=$(tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | grep "e2e-test-agent-creation-$$" | cut -d: -f1)
if [[ -n "$PM_SESSIONS" ]]; then
    pass "PM session exists: $(echo "$PM_SESSIONS" | head -1)"
else
    # Check if output mentions session creation
    if echo "$SKILL_OUTPUT" | grep -qi "Session ready\|tmux attach\|Switching to PM"; then
        pass "Skill reported session creation"
    else
        fail "PM session not found and skill didn't report creation"
    fi
fi

# Test 5: Check skill completed (look for completion indicators)
echo ""
echo "Testing skill completion..."
if echo "$SKILL_OUTPUT" | grep -qi "Session ready\|tmux attach\|Switching to PM\|PM session\|Deploy"; then
    pass "Skill completed (session/deploy message found)"
else
    fail "Skill completion message not found"
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
