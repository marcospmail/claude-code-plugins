#!/bin/bash
# test-system-constraints-in-constraints-md.sh
#
# E2E Test: System Constraints in constraints.md
#
# Verifies that when agents are created via agent_manager.py init-files,
# their constraints.md contains the "System Constraints" section with
# the key prohibition rules that were moved from instructions.md.
#
# Tests both developer and QA agents to ensure all non-PM agents get
# the system constraints section.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="system-constraints"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-sysconst-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: System Constraints in constraints.md"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "  PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "  FAIL: $1"
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
echo "test" > "$TEST_DIR/app.js"

cd "$TEST_DIR" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  - Project: $TEST_DIR"
echo ""

# ============================================================
# PHASE 2: Initialize workflow
# ============================================================
echo "Phase 2: Running init-workflow.sh..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test system constraints'" Enter
sleep 5

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -z "$WORKFLOW_NAME" ]]; then
    fail "No workflow folder found"
    exit 1
fi

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Create developer agent via save_team_structure
# ============================================================
echo "Phase 3: Creating developer agent..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "source $PROJECT_ROOT/bin/workflow-utils.sh && save_team_structure '$TEST_DIR' dev:developer:sonnet" Enter
sleep 5

echo "  - Developer agent created"
echo ""

# ============================================================
# PHASE 4: Create QA agent via agent_manager.py
# ============================================================
echo "Phase 4: Creating QA agent via agent_manager.py..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "cd '$TEST_DIR' && WORKFLOW_NAME=$WORKFLOW_NAME uv run python $PROJECT_ROOT/lib/agent_manager.py init-files qa qa -p '$TEST_DIR'" Enter
sleep 8

echo "  - QA agent created"
echo ""

# ============================================================
# PHASE 5: Verify developer constraints.md has System Constraints
# ============================================================
echo "Phase 5: Checking developer constraints.md..."

DEV_CONSTRAINTS="$WORKFLOW_PATH/agents/dev/constraints.md"

if [[ -f "$DEV_CONSTRAINTS" ]]; then
    pass "Developer constraints.md exists"
else
    fail "Developer constraints.md not found at $DEV_CONSTRAINTS"
fi

# Check for System Constraints header
if grep -q "## System Constraints" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Developer constraints.md has '## System Constraints' section"
else
    fail "Developer constraints.md missing '## System Constraints' section"
fi

# Check key prohibition rules
if grep -q "NEVER communicate directly with the user" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Contains: NEVER communicate directly with the user"
else
    fail "Missing: NEVER communicate directly with the user"
fi

if grep -q "DO NOT ask the user questions using AskUserQuestion" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Contains: DO NOT ask the user questions using AskUserQuestion"
else
    fail "Missing: DO NOT ask the user questions using AskUserQuestion"
fi

if grep -q "DO NOT wait for user input or confirmation" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Contains: DO NOT wait for user input or confirmation"
else
    fail "Missing: DO NOT wait for user input or confirmation"
fi

if grep -q "DO NOT output messages intended for the user" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Contains: DO NOT output messages intended for the user"
else
    fail "Missing: DO NOT output messages intended for the user"
fi

if grep -q "NEVER stop working silently" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Contains: NEVER stop working silently"
else
    fail "Missing: NEVER stop working silently"
fi

if grep -qi "polling\|infinite" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Contains: infinite polling prohibition"
else
    fail "Missing: infinite polling prohibition"
fi

echo ""

# ============================================================
# PHASE 6: Verify QA constraints.md has System Constraints
# ============================================================
echo "Phase 6: Checking QA constraints.md..."

QA_CONSTRAINTS="$WORKFLOW_PATH/agents/qa/constraints.md"

if [[ -f "$QA_CONSTRAINTS" ]]; then
    pass "QA constraints.md exists"
else
    fail "QA constraints.md not found at $QA_CONSTRAINTS"
fi

if grep -q "## System Constraints" "$QA_CONSTRAINTS" 2>/dev/null; then
    pass "QA constraints.md has '## System Constraints' section"
else
    fail "QA constraints.md missing '## System Constraints' section"
fi

if grep -q "NEVER communicate directly with the user" "$QA_CONSTRAINTS" 2>/dev/null; then
    pass "QA contains: NEVER communicate directly with the user"
else
    fail "QA missing: NEVER communicate directly with the user"
fi

if grep -q "DO NOT ask the user questions using AskUserQuestion" "$QA_CONSTRAINTS" 2>/dev/null; then
    pass "QA contains: DO NOT ask the user questions using AskUserQuestion"
else
    fail "QA missing: DO NOT ask the user questions using AskUserQuestion"
fi

echo ""

# ============================================================
# PHASE 7: Verify constraints.md has Project Constraints section
# ============================================================
echo "Phase 7: Checking Project Constraints section..."

if grep -q "## Project Constraints" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Developer constraints.md has '## Project Constraints' section"
else
    fail "Developer constraints.md missing '## Project Constraints' section"
fi

if grep -q "Add project-specific constraints" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Developer constraints.md has customization hints"
else
    fail "Developer constraints.md missing customization hints"
fi

echo ""

# ============================================================
# RESULTS
# ============================================================
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    EXIT_CODE=0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    EXIT_CODE=1
fi
echo "======================================================================"
echo ""

exit $EXIT_CODE
