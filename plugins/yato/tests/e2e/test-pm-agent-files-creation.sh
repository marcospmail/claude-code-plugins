#!/bin/bash
# test-pm-agent-files-creation.sh
#
# E2E Test: PM Agent Files Created by deploy-pm
#
# Verifies that orchestrator.py deploy-pm calls agent_manager.py init-files
# to create PM agent files when the PM agent directory does not exist:
# 1. identity.yml, instructions.md, constraints.md, CLAUDE.md, agent-tasks.md
# 2. constraints.md has "System Constraints" and "PM-Specific Constraints" sections
# 3. instructions.md has positive guidance (Role, Communication sections)
#
# The deploy-pm path now calls agent_manager.py init-files to create these files,
# whereas previously the PM was deployed without them.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-agent-files"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-pmfiles-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: PM Agent Files Created by deploy-pm"
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

echo "  - Project: $TEST_DIR"
echo ""

# ============================================================
# PHASE 2: Initialize workflow and remove PM dir
# ============================================================
echo "Phase 2: Creating workflow structure..."

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test PM agent files'" Enter
sleep 5

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -z "$WORKFLOW_NAME" ]]; then
    fail "No workflow folder found"
    exit 1
fi

echo "  - Workflow: $WORKFLOW_NAME"

# Remove PM agent dir so deploy-pm will trigger agent_manager.py init-files
rm -rf "$WORKFLOW_PATH/agents/pm"
echo "  - Removed PM agent dir (so deploy-pm creates it via agent_manager.py)"
echo ""

# Kill the temp session - deploy-pm creates its own
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true

# ============================================================
# PHASE 3: Deploy PM via orchestrator.py deploy-pm
# ============================================================
echo "Phase 3: Deploying PM via orchestrator.py deploy-pm..."

cd "$TEST_DIR" && WORKFLOW_NAME="$WORKFLOW_NAME" uv run --directory "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/orchestrator.py" deploy-pm "$SESSION_NAME" -p "$TEST_DIR" -w "$WORKFLOW_NAME" 2>&1 >/dev/null

sleep 3

echo "  - PM deployed"
echo ""

# ============================================================
# PHASE 4: Verify PM agent files exist
# ============================================================
echo "Phase 4: Verifying PM agent files..."

PM_DIR="$WORKFLOW_PATH/agents/pm"

if [[ -d "$PM_DIR" ]]; then
    pass "agents/pm/ directory exists"
else
    fail "agents/pm/ directory not found at $PM_DIR"
fi

if [[ -f "$PM_DIR/identity.yml" ]]; then
    pass "identity.yml exists"
else
    fail "identity.yml not found"
fi

if [[ -f "$PM_DIR/instructions.md" ]]; then
    pass "instructions.md exists"
else
    fail "instructions.md not found"
fi

if [[ -f "$PM_DIR/constraints.md" ]]; then
    pass "constraints.md exists"
else
    fail "constraints.md not found"
fi

if [[ -f "$PM_DIR/CLAUDE.md" ]]; then
    pass "CLAUDE.md exists"
else
    fail "CLAUDE.md not found"
fi

if [[ -f "$PM_DIR/agent-tasks.md" ]]; then
    pass "agent-tasks.md exists"
else
    fail "agent-tasks.md not found"
fi

echo ""

# ============================================================
# PHASE 5: Verify constraints.md sections
# ============================================================
echo "Phase 5: Verifying constraints.md content..."

PM_CONSTRAINTS="$PM_DIR/constraints.md"

if grep -q "## System Constraints" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "constraints.md has '## System Constraints' section"
else
    fail "constraints.md missing '## System Constraints' section"
fi

if grep -q "## PM-Specific Constraints" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "constraints.md has '## PM-Specific Constraints' section"
else
    fail "constraints.md missing '## PM-Specific Constraints' section"
fi

# Verify key system constraints are present
if grep -q "NEVER communicate directly with the user" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "System constraint: NEVER communicate directly with the user"
else
    fail "Missing system constraint: NEVER communicate directly with the user"
fi

# Verify key PM-specific constraints
if grep -qi "cannot modify.*code" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "PM constraint: cannot modify code"
else
    fail "Missing PM constraint: cannot modify code"
fi

if grep -q "NEVER call cancel-checkin" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "PM constraint: NEVER call cancel-checkin"
else
    fail "Missing PM constraint: NEVER call cancel-checkin"
fi

echo ""

# ============================================================
# PHASE 6: Verify instructions.md has positive guidance
# ============================================================
echo "Phase 6: Verifying instructions.md content..."

PM_INSTRUCTIONS="$PM_DIR/instructions.md"

if grep -q "## Role" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Role' section"
else
    fail "instructions.md missing '## Role' section"
fi

if grep -q "## Communication" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Communication' section"
else
    fail "instructions.md missing '## Communication' section"
fi

if grep -q "## Task Management" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Task Management' section (PM-specific)"
else
    fail "instructions.md missing '## Task Management' section"
fi

if grep -q "## Waiting for Dependencies" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Waiting for Dependencies' section"
else
    fail "instructions.md missing '## Waiting for Dependencies' section"
fi

# instructions.md should NOT contain system prohibition rules (those are in constraints.md)
if grep -q "NEVER communicate directly with the user" "$PM_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains system constraints (should be in constraints.md only)"
else
    pass "instructions.md does not contain system constraints (correct)"
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
