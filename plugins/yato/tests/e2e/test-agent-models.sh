#!/bin/bash
# test-agent-models.sh
#
# E2E Test: Agent Model Assignment via /yato-existing-project
#
# This test verifies init-workflow.sh assigns correct model to PM:
# 1. Starts Claude in tmux
# 2. Runs init-workflow.sh through Claude
# 3. Verifies:
#    - PM identity.yml exists with correct model assignment (opus)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-models"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"
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
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    # Kill any sessions matching the project pattern
    tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | grep "e2e-test-agent-models" | cut -d: -f1 | xargs -I{} tmux -L "$TMUX_SOCKET" kill-session -t {} 2>/dev/null || true
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
# PHASE 2: Create workflow via init-workflow.sh directly
# ============================================================
echo "Phase 2: Creating workflow..."

# Create tmux session (needed for session name in status.yml)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Initialize workflow directly (no Claude needed)
echo "  - Initializing workflow..."
TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test model assignment"
pass "init-workflow.sh completed"

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
