#!/bin/bash
# test-smart-naming-duplicates.sh
#
# E2E Test: Smart Naming with Duplicate Roles
#
# Verifies that when multiple agents of the same role are created,
# they get numbered names (qa-1, qa-2) while single roles stay unnumbered.
#
# Team: developer + qa + qa + code-reviewer
# Expected: developer, qa-1, qa-2, code-reviewer

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="smart-naming-duplicates"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Smart Naming with Duplicate Roles"
echo "======================================================================"
echo ""
echo "Team: developer + qa + qa + code-reviewer"
echo "Expected: developer (no #), qa-1, qa-2, code-reviewer (no #)"
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
echo "function test() { return true; }" > "$TEST_DIR/app.js"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Create workflow
# ============================================================
echo "Phase 2: Creating workflow..."

TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test smart naming duplicates"

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
AGENTS_YML="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents.yml"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Create team with duplicate roles
# ============================================================
echo "Phase 3: Creating team with duplicate QA roles..."

# Use agent_manager.py create to test smart naming
# Each call should auto-number duplicates
cd "$PROJECT_ROOT"

TMUX_SOCKET="$TMUX_SOCKET" uv run python lib/agent_manager.py create "$SESSION_NAME" developer -p "$TEST_DIR" --no-start --no-brief 2>&1 || true
TMUX_SOCKET="$TMUX_SOCKET" uv run python lib/agent_manager.py create "$SESSION_NAME" qa -p "$TEST_DIR" --no-start --no-brief 2>&1 || true
TMUX_SOCKET="$TMUX_SOCKET" uv run python lib/agent_manager.py create "$SESSION_NAME" qa -p "$TEST_DIR" --no-start --no-brief 2>&1 || true
TMUX_SOCKET="$TMUX_SOCKET" uv run python lib/agent_manager.py create "$SESSION_NAME" code-reviewer -p "$TEST_DIR" --no-start --no-brief 2>&1 || true

echo "  - Team creation completed"
echo ""

# ============================================================
# PHASE 4: Verify smart naming
# ============================================================
echo "Phase 4: Verifying smart naming..."

# Test agents.yml content
echo ""
echo "Testing agents.yml entries..."

if [[ -f "$AGENTS_YML" ]]; then
    pass "agents.yml exists"
else
    fail "agents.yml not found at $AGENTS_YML"
fi

if grep -q 'name: "developer"' "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: developer (no suffix)"
else
    fail "agents.yml should have 'developer' not 'developer-1'"
fi

if grep -q 'name: "qa-1"' "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: qa-1"
else
    fail "agents.yml should have 'qa-1'"
fi

if grep -q 'name: "qa-2"' "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: qa-2"
else
    fail "agents.yml should have 'qa-2'"
fi

if grep -q 'name: "code-reviewer"' "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: code-reviewer (no suffix)"
else
    fail "agents.yml should have 'code-reviewer' not 'code-reviewer-1'"
fi

# ============================================================
# PHASE 5: Verify agent directories
# ============================================================
echo ""
echo "Phase 5: Verifying agent directories..."

AGENTS_DIR="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents"

if [[ -d "$AGENTS_DIR/developer" ]]; then
    pass "developer agent directory exists"
else
    fail "developer agent directory not found"
fi

if [[ -d "$AGENTS_DIR/qa-1" ]]; then
    pass "qa-1 agent directory exists"
else
    fail "qa-1 agent directory not found"
fi

if [[ -d "$AGENTS_DIR/qa-2" ]]; then
    pass "qa-2 agent directory exists"
else
    fail "qa-2 agent directory not found"
fi

if [[ -d "$AGENTS_DIR/code-reviewer" ]]; then
    pass "code-reviewer agent directory exists"
else
    fail "code-reviewer agent directory not found"
fi

# ============================================================
# PHASE 6: Verify model assignments
# ============================================================
echo ""
echo "Phase 6: Verifying model assignments..."

CR_MODEL=$(grep -A 5 'name: "code-reviewer"' "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
CR_MODEL=$(echo "$CR_MODEL" | tr -d '"')
if [[ "$CR_MODEL" == "opus" ]]; then
    pass "code-reviewer uses opus model"
else
    fail "code-reviewer should use opus, got: $CR_MODEL"
fi

DEV_MODEL=$(grep -A 5 'name: "developer"' "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
DEV_MODEL=$(echo "$DEV_MODEL" | tr -d '"')
if [[ "$DEV_MODEL" == "sonnet" ]]; then
    pass "developer uses sonnet model"
else
    fail "developer should use sonnet, got: $DEV_MODEL"
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
