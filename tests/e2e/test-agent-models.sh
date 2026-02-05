#!/bin/bash
# test-agent-models.sh
#
# E2E Test: Agent Model Assignment via /yato-existing-project
#
# This test verifies the /yato-existing-project skill assigns correct model to PM:
# 1. Starts Claude in tmux with --dangerously-skip-permissions
# 2. Invokes /yato-existing-project skill
# 3. Verifies:
#    - PM identity.yml exists with correct model assignment (opus)
#
# This tests PLUGIN INTEGRATION, not the full multi-minute PM workflow.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-models"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
PROJECT_SLUG="e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Model Assignment via /yato-existing-project ║"
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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    # Kill any sessions matching the project pattern
    tmux list-sessions 2>/dev/null | grep "e2e-test-agent-models" | cut -d: -f1 | xargs -I{} tmux kill-session -t {} 2>/dev/null || true
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
tmux new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Start Claude with --dangerously-skip-permissions
tmux send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter

echo "  - Waiting for Claude to initialize (12 seconds)..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started"
else
    fail "Claude prompt not visible"
fi

# Invoke /yato-existing-project skill
echo "  - Invoking /yato-existing-project skill..."
tmux send-keys -t "$SESSION_NAME" "/yato-existing-project Test model assignment"
sleep 2
tmux send-keys -t "$SESSION_NAME" Enter

# Poll for workflow folder creation instead of fixed sleep
echo "  - Polling for workflow folder (max 240 seconds)..."
POLL_START=$(date +%s)
POLL_MAX=240
POLL_INTERVAL=15
WORKFLOW_FOUND=false

# Initial wait to let skill start
sleep 60

while true; do
    ELAPSED=$(($(date +%s) - POLL_START))

    # Check if workflow folder exists
    WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
    if [[ -n "$WORKFLOW_DIR" ]] && [[ -d "$WORKFLOW_DIR" ]]; then
        echo "  - Workflow folder found after ${ELAPSED}s"
        WORKFLOW_FOUND=true
        # Wait a bit more for PM files to be created
        sleep 30
        break
    fi

    # Check timeout
    if [[ $ELAPSED -ge $POLL_MAX ]]; then
        echo "  - Timeout after ${ELAPSED}s"
        break
    fi

    echo "  - Polling... (${ELAPSED}s elapsed)"
    sleep $POLL_INTERVAL
done

# Capture output for debugging
SKILL_OUTPUT=$(tmux capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)
echo ""
echo "Debug - Skill output (last 20 lines):"
echo "$SKILL_OUTPUT" | tail -20
echo ""

# ============================================================
# PHASE 3: Verify PM model assignment
# ============================================================
echo "Phase 3: Verifying PM model assignment..."
echo ""

# Find workflow folder
WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
if [[ -n "$WORKFLOW_DIR" ]] && [[ -d "$WORKFLOW_DIR" ]]; then
    WORKFLOW_NAME=$(basename "$WORKFLOW_DIR")
    pass "Workflow folder created: $WORKFLOW_NAME"
else
    fail "Workflow folder not created"
    WORKFLOW_NAME=""
fi

# Find PM agent folder
PM_AGENT_DIR="$WORKFLOW_DIR/agents/pm"
PM_IDENTITY="$PM_AGENT_DIR/identity.yml"

echo ""
echo "Testing PM model in identity.yml..."

# Test 1: PM identity.yml exists
if [[ -f "$PM_IDENTITY" ]]; then
    pass "PM identity.yml exists"

    # Test 2: PM model is opus
    PM_MODEL=$(grep "model:" "$PM_IDENTITY" | head -1 | awk '{print $2}')
    if [[ "$PM_MODEL" == "opus" ]]; then
        pass "PM uses opus model"
    else
        fail "PM should use opus, got: $PM_MODEL"
    fi

    # Test 3: PM has role field
    if grep -q "role:" "$PM_IDENTITY"; then
        pass "PM identity has role field"
    else
        fail "PM identity missing role field"
    fi
else
    fail "PM identity.yml not found at $PM_IDENTITY"
fi

echo ""
echo "Testing status.yml..."

# Test 4: status.yml exists with session field
if [[ -n "$WORKFLOW_NAME" ]] && [[ -f "$WORKFLOW_DIR/status.yml" ]]; then
    pass "status.yml exists"

    if grep -q "session:" "$WORKFLOW_DIR/status.yml"; then
        pass "status.yml has session field"
    else
        fail "status.yml missing session field"
    fi
else
    fail "status.yml not found"
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
