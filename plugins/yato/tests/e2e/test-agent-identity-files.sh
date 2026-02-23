#!/bin/bash
# test-agent-identity-files.sh
#
# E2E Test: Agent Identity Files
#
# This test verifies init-workflow.sh creates correct PM identity files:
# 1. Creates a tmux session
# 2. Runs init-workflow.sh directly
# 3. Verifies:
#    - PM identity.yml exists with correct fields
#    - PM instructions.md exists with correct content
#    - status.yml has session field

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-identity-files"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"
PROJECT_SLUG="e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Identity Files                              ║"
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
    tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | grep "e2e-test-agent-identity" | cut -d: -f1 | xargs -I{} tmux -L "$TMUX_SOCKET" kill-session -t {} 2>/dev/null || true
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
# PHASE 2: Create workflow via init-workflow.sh
# ============================================================
echo "Phase 2: Creating workflow..."

# Create tmux session (needed for session name detection)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Initialize workflow directly
echo "  - Initializing workflow..."
TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test identity file generation"
pass "init-workflow.sh completed"

# ============================================================
# PHASE 3: Verify PM identity files
# ============================================================
echo "Phase 3: Verifying PM identity files..."
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

echo ""
echo "Testing PM identity.yml..."

# Test 1: PM identity.yml exists
PM_IDENTITY="$PM_AGENT_DIR/identity.yml"
if [[ -f "$PM_IDENTITY" ]]; then
    pass "PM identity.yml exists"

    # Test 2: PM has role field
    if grep -q "role:" "$PM_IDENTITY"; then
        pass "PM identity has role field"
    else
        fail "PM identity missing role field"
    fi

    # Test 3: PM has model field
    if grep -q "model:" "$PM_IDENTITY"; then
        pass "PM identity has model field"
    else
        fail "PM identity missing model field"
    fi

    # Test 4: PM has session and window fields (for role detection)
    if grep -q "session:" "$PM_IDENTITY" && grep -q "window:" "$PM_IDENTITY"; then
        pass "PM identity has session and window fields"
    else
        fail "PM identity should have session and window fields"
    fi
else
    fail "PM identity.yml not found at $PM_IDENTITY"
fi

echo ""
echo "Testing PM instructions.md..."

# Test 5: PM instructions.md exists
PM_INSTRUCTIONS="$PM_AGENT_DIR/instructions.md"
if [[ -f "$PM_INSTRUCTIONS" ]]; then
    pass "PM instructions.md exists"

    # Test 6: PM instructions contain key responsibilities
    if grep -qi "PM\|coordinate\|delegate\|team\|agent" "$PM_INSTRUCTIONS"; then
        pass "PM instructions contain PM responsibilities"
    else
        fail "PM instructions missing PM responsibilities"
    fi
else
    fail "PM instructions.md not found"
fi

echo ""
echo "Testing PM CLAUDE.md..."

# Test 7: PM CLAUDE.md exists (optional - may not be created by all deployment methods)
PM_CLAUDE="$PM_AGENT_DIR/CLAUDE.md"
if [[ -f "$PM_CLAUDE" ]]; then
    pass "PM CLAUDE.md exists"

    # Test 8: CLAUDE.md references identity.yml
    if grep -q "identity.yml\|identity" "$PM_CLAUDE"; then
        pass "PM CLAUDE.md references identity"
    else
        echo "  ⚠️  PM CLAUDE.md doesn't reference identity (non-critical)"
    fi
else
    # CLAUDE.md is optional - PM may use project-level CLAUDE.md instead
    echo "  ⚠️  PM CLAUDE.md not found (non-critical - PM may use project CLAUDE.md)"
fi

echo ""
echo "Testing status.yml..."

# Test 9: status.yml exists with session field
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
