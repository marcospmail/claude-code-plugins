#!/bin/bash
# test-smart-naming-duplicates.sh
#
# E2E Test: Smart Naming with Duplicate Roles
#
# This test verifies that when multiple agents of the same role are created,
# they get numbered names (qa-1, qa-2) while single roles stay unnumbered.
#
# Team: developer + qa + qa + code-reviewer
# Expected: developer, qa-1, qa-2, code-reviewer

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="smart-naming-duplicates"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-dup-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Smart Naming with Duplicate Roles                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test: developer + qa + qa + code-reviewer"
echo "Expected: developer (no #), qa-1, qa-2, code-reviewer (no #)"
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
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -n "pm-checkins" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh $TEST_DIR 'Test smart naming duplicates'" Enter
sleep 3

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "$WORKFLOW_NAME"
AGENTS_YML="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents.yml"

echo "  - Session: $SESSION_NAME"
echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 2: Create team with duplicate roles
# ============================================================
echo "Phase 2: Creating team with duplicate QA roles..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $PROJECT_ROOT/bin/create-team.sh $TEST_DIR developer qa qa code-reviewer" Enter

# Wait for all 4 agents to be created
sleep 35

echo "  - Team creation completed"
echo ""

# ============================================================
# PHASE 3: Verify smart naming
# ============================================================
echo "Phase 3: Verifying smart naming..."
echo ""

# Test window count
WINDOWS=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WINDOWS" -ge 5 ]]; then
    pass "Created 5 windows (PM + 4 agents)"
else
    fail "Expected 5 windows, got $WINDOWS"
fi

# Test window names
echo ""
echo "Testing window names..."
WINDOW_LIST=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" 2>/dev/null)

if echo "$WINDOW_LIST" | grep -q "1:developer"; then
    pass "Window 1: 'developer' (single role, no number)"
else
    fail "Window 1 should be 'developer'"
fi

if echo "$WINDOW_LIST" | grep -q "2:qa-1"; then
    pass "Window 2: 'qa-1' (first of duplicate)"
else
    fail "Window 2 should be 'qa-1'"
fi

if echo "$WINDOW_LIST" | grep -q "3:qa-2"; then
    pass "Window 3: 'qa-2' (second of duplicate)"
else
    fail "Window 3 should be 'qa-2'"
fi

if echo "$WINDOW_LIST" | grep -q "4:code-reviewer"; then
    pass "Window 4: 'code-reviewer' (single role, no number)"
else
    fail "Window 4 should be 'code-reviewer'"
fi

# Test agents.yml content
echo ""
echo "Testing agents.yml entries..."

if grep -q "name: developer$" "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: developer (no suffix)"
else
    fail "agents.yml should have 'developer' not 'developer-1'"
fi

if grep -q "name: qa-1$" "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: qa-1"
else
    fail "agents.yml should have 'qa-1'"
fi

if grep -q "name: qa-2$" "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: qa-2"
else
    fail "agents.yml should have 'qa-2'"
fi

if grep -q "name: code-reviewer$" "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml: code-reviewer (no suffix)"
else
    fail "agents.yml should have 'code-reviewer' not 'code-reviewer-1'"
fi

# Test models
echo ""
echo "Testing model assignments..."

# code-reviewer should have opus
CR_MODEL=$(grep -A 5 "name: code-reviewer$" "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
if [[ "$CR_MODEL" == "opus" ]]; then
    pass "code-reviewer uses opus model"
else
    fail "code-reviewer should use opus, got: $CR_MODEL"
fi

# developer should have sonnet
DEV_MODEL=$(grep -A 5 "name: developer$" "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
if [[ "$DEV_MODEL" == "sonnet" ]]; then
    pass "developer uses sonnet model"
else
    fail "developer should use sonnet, got: $DEV_MODEL"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                 ║"
    EXIT_CODE=0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                       ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
