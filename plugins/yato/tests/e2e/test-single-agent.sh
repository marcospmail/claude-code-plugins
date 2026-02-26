#!/bin/bash
# test-single-agent.sh
#
# E2E Test: Single Agent Creation
#
# Verifies that creating a single agent works correctly:
# - agents.yml has the agent entry
# - Agent is named 'qa' (not 'qa-1')
# - Agent files are generated

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="single-agent"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Single Agent Creation"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Create workflow
# ============================================================
echo "Phase 2: Creating workflow..."

TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Single agent test"

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
AGENTS_YML="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents.yml"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Create single QA agent
# ============================================================
echo "Phase 3: Creating single QA agent..."

source "$PROJECT_ROOT/bin/workflow-utils.sh"
save_team_structure "$TEST_DIR" "qa:qa:sonnet"

echo ""

# ============================================================
# PHASE 4: Verify agent creation
# ============================================================
echo "Phase 4: Verifying agent creation..."

# Check agents.yml was created/updated
if [[ -f "$AGENTS_YML" ]]; then
    pass "agents.yml exists"
else
    fail "agents.yml not found at $AGENTS_YML"
fi

# Check the agent is named 'qa' (not 'qa-1')
if grep -q 'name: "qa"' "$AGENTS_YML" 2>/dev/null; then
    pass "Single QA named 'qa' (no number suffix)"
else
    fail "Single QA should be named 'qa' not 'qa-1'"
fi

# Check agent role is correct
if grep -q 'role: "qa"' "$AGENTS_YML" 2>/dev/null; then
    pass "QA agent has correct role"
else
    fail "QA agent missing correct role"
fi

# Check agent files were generated
QA_DIR="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents/qa"
if [[ -d "$QA_DIR" ]]; then
    pass "QA agent directory created"
else
    fail "QA agent directory not found at $QA_DIR"
fi

if [[ -f "$QA_DIR/instructions.md" ]]; then
    pass "QA agent instructions.md created"
else
    fail "QA agent instructions.md not found"
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
