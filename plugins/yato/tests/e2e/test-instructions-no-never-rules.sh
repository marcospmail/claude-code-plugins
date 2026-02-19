#!/bin/bash
# test-instructions-no-never-rules.sh
#
# E2E Test: instructions.md No Longer Contains NEVER/DO NOT Prohibition Rules
#
# After the refactor, all prohibition rules (NEVER, DO NOT) were moved from
# instructions.md to constraints.md. This test verifies that instructions.md
# only contains positive guidance (role, responsibilities, communication,
# waiting for dependencies) and no longer has the old "CRITICAL RULE" section
# or system-level prohibition rules.
#
# Note: instructions.md may still contain role-specific "Do NOT" in responsibilities
# (e.g., QA: "Do NOT modify production code") - those are role descriptions, not
# system constraints. We specifically check for the SYSTEM prohibition rules that
# were moved to constraints.md.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="instructions-no-never"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-nonever-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: instructions.md No Longer Contains NEVER/DO NOT Rules"
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

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test no never rules'" Enter
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
# PHASE 3: Create agents via save_team_structure (bash path)
# ============================================================
echo "Phase 3: Creating developer agent via save_team_structure..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "source $PROJECT_ROOT/bin/workflow-utils.sh && save_team_structure '$TEST_DIR' dev:developer:sonnet" Enter
sleep 5

echo "  - Developer agent created"
echo ""

# ============================================================
# PHASE 4: Create PM agent via agent_manager.py (Python path)
# ============================================================
echo "Phase 4: Creating PM agent via agent_manager.py..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "cd '$TEST_DIR' && WORKFLOW_NAME=$WORKFLOW_NAME uv run python $PROJECT_ROOT/lib/agent_manager.py init-files pm pm -p '$TEST_DIR'" Enter
sleep 8

echo "  - PM agent created"
echo ""

# ============================================================
# PHASE 5: Verify developer instructions.md has NO system prohibition rules
# ============================================================
echo "Phase 5: Checking developer instructions.md for absence of system constraints..."

DEV_INSTRUCTIONS="$WORKFLOW_PATH/agents/dev/instructions.md"

if [[ -f "$DEV_INSTRUCTIONS" ]]; then
    pass "Developer instructions.md exists"
else
    fail "Developer instructions.md not found at $DEV_INSTRUCTIONS"
    exit 1
fi

# The old "CRITICAL RULE - READ FIRST" section should be gone
if grep -qi "CRITICAL RULE" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains 'CRITICAL RULE' section (should be removed)"
else
    pass "No 'CRITICAL RULE' section in instructions.md"
fi

# System constraint: NEVER communicate directly with the user
if grep -q "NEVER communicate directly with the user" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains 'NEVER communicate directly with the user' (moved to constraints.md)"
else
    pass "No 'NEVER communicate directly with the user' in instructions.md"
fi

# System constraint: DO NOT ask the user questions
if grep -q "DO NOT ask the user questions using AskUserQuestion" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains AskUserQuestion prohibition (moved to constraints.md)"
else
    pass "No AskUserQuestion prohibition in instructions.md"
fi

# System constraint: DO NOT wait for user input
if grep -q "DO NOT wait for user input or confirmation" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains 'DO NOT wait for user input' (moved to constraints.md)"
else
    pass "No 'DO NOT wait for user input' in instructions.md"
fi

# System constraint: DO NOT output messages intended for the user
if grep -q "DO NOT output messages intended for the user" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains 'DO NOT output messages intended for the user' (moved to constraints.md)"
else
    pass "No 'DO NOT output messages intended for the user' in instructions.md"
fi

# System constraint: NEVER stop working silently
if grep -q "NEVER stop working silently" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains 'NEVER stop working silently' (moved to constraints.md)"
else
    pass "No 'NEVER stop working silently' in instructions.md"
fi

# System constraint: infinite polling prohibition
if grep -q "DO NOT enter infinite polling loops" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    fail "instructions.md still contains 'DO NOT enter infinite polling loops' (moved to constraints.md)"
else
    pass "No 'DO NOT enter infinite polling loops' in instructions.md"
fi

echo ""

# ============================================================
# PHASE 6: Verify instructions.md STILL has positive guidance
# ============================================================
echo "Phase 6: Checking instructions.md still has positive guidance..."

# Should still have role section
if grep -q "## Role" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Role' section"
else
    fail "instructions.md missing '## Role' section"
fi

# Should still have responsibilities
if grep -q "## Responsibilities" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Responsibilities' section"
else
    fail "instructions.md missing '## Responsibilities' section"
fi

# Should still have communication section
if grep -q "## Communication" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Communication' section"
else
    fail "instructions.md missing '## Communication' section"
fi

# Should still have waiting for dependencies section
if grep -q "## Waiting for Dependencies" "$DEV_INSTRUCTIONS" 2>/dev/null; then
    pass "instructions.md has '## Waiting for Dependencies' section"
else
    fail "instructions.md missing '## Waiting for Dependencies' section"
fi

echo ""

# ============================================================
# PHASE 7: Verify PM instructions.md also has no system constraints
# ============================================================
echo "Phase 7: Checking PM instructions.md for absence of system constraints..."

PM_INSTRUCTIONS="$WORKFLOW_PATH/agents/pm/instructions.md"

if [[ -f "$PM_INSTRUCTIONS" ]]; then
    pass "PM instructions.md exists"
else
    fail "PM instructions.md not found at $PM_INSTRUCTIONS"
fi

if grep -q "NEVER communicate directly with the user" "$PM_INSTRUCTIONS" 2>/dev/null; then
    fail "PM instructions.md still contains 'NEVER communicate directly with the user'"
else
    pass "PM instructions.md has no 'NEVER communicate directly with the user'"
fi

if grep -q "DO NOT ask the user questions using AskUserQuestion" "$PM_INSTRUCTIONS" 2>/dev/null; then
    fail "PM instructions.md still contains AskUserQuestion prohibition"
else
    pass "PM instructions.md has no AskUserQuestion prohibition"
fi

# PM instructions.md should still have Task Management section
if grep -q "## Task Management" "$PM_INSTRUCTIONS" 2>/dev/null; then
    pass "PM instructions.md has '## Task Management' section"
else
    fail "PM instructions.md missing '## Task Management' section"
fi

echo ""

# ============================================================
# PHASE 8: Verify the template source also has no system constraints
# ============================================================
echo "Phase 8: Checking init-agent-files.sh template..."

INIT_SCRIPT="$PROJECT_ROOT/bin/init-agent-files.sh"

if grep -q "NEVER communicate directly with the user" "$INIT_SCRIPT" 2>/dev/null; then
    # This is expected - it's in the constraints.md generation section, not instructions.md
    # Check it's NOT in the instructions.md heredoc
    # The instructions.md content is between 'cat > "$AGENT_DIR/instructions.md"' and the next 'EOF'
    INSTRUCTIONS_SECTION=$(sed -n '/cat > "\$AGENT_DIR\/instructions.md"/,/^EOF$/p' "$INIT_SCRIPT" 2>/dev/null)
    if echo "$INSTRUCTIONS_SECTION" | grep -q "NEVER communicate directly with the user" 2>/dev/null; then
        fail "init-agent-files.sh instructions.md template still contains system constraints"
    else
        pass "init-agent-files.sh: system constraints only in constraints.md section, not instructions.md"
    fi
else
    pass "init-agent-files.sh does not contain 'NEVER communicate' in instructions template"
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
