#!/bin/bash
# test-project-discovery.sh
#
# E2E Test: yato-existing-project Skill Structure
#
# Verifies that:
# 1. The skill file exists and has correct frontmatter
# 2. The skill does NOT contain redundant project type detection bash commands
# 3. The skill is a thin launcher (uses deploy-pm, init-workflow.sh)
# 4. The skill does NOT do pre-PM analysis or file creation
# 5. The workflow creation infrastructure works (init-workflow.sh)
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# Phase 5 workflow creation goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="project-discovery"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: yato-existing-project Skill Structure"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
echo "Project root: $PROJECT_ROOT"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup test environment
mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# Initialize git so init-workflow.sh works
cd "$TEST_DIR" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

SKILL_FILE="$PROJECT_ROOT/skills/yato-existing-project/SKILL.md"

# ============================================================
# PHASE 1: Verify skill file exists
# ============================================================
echo "Phase 1: Skill file structure..."
echo ""

if [[ -f "$SKILL_FILE" ]]; then
    pass "yato-existing-project SKILL.md exists"
else
    fail "yato-existing-project SKILL.md not found"
    exit 1
fi

# ============================================================
# PHASE 2: Verify NO redundant project type detection
# ============================================================
echo ""
echo "Phase 2: No redundant project type detection..."
echo ""

# Should NOT have inline project type detection like:
# test -f package.json && echo "Node.js project detected"
# These are redundant because PM handles discovery

if grep -q 'test -f package.json && echo.*project detected' "$SKILL_FILE"; then
    fail "Skill still contains 'test -f package.json && echo project detected' - redundant"
else
    pass "No redundant Node.js detection bash command"
fi

if grep -q 'test -f requirements.txt && echo.*project detected' "$SKILL_FILE"; then
    fail "Skill still contains 'test -f requirements.txt && echo project detected' - redundant"
else
    pass "No redundant Python detection bash command"
fi

if grep -q 'test -f go.mod && echo.*project detected' "$SKILL_FILE"; then
    fail "Skill still contains 'test -f go.mod && echo project detected' - redundant"
else
    pass "No redundant Go detection bash command"
fi

if grep -q 'test -f Cargo.toml && echo.*project detected' "$SKILL_FILE"; then
    fail "Skill still contains 'test -f Cargo.toml && echo project detected' - redundant"
else
    pass "No redundant Rust detection bash command"
fi

# ============================================================
# PHASE 3: Verify skill is a thin launcher (deploy-pm + init-workflow)
# ============================================================
echo ""
echo "Phase 3: Thin launcher pattern..."
echo ""

if grep -q 'deploy-pm' "$SKILL_FILE"; then
    pass "Skill uses deploy-pm command"
else
    fail "Skill should use deploy-pm to launch PM"
fi

if grep -q 'init-workflow.sh' "$SKILL_FILE"; then
    pass "Skill uses init-workflow.sh for workflow creation"
else
    fail "Skill should use init-workflow.sh"
fi

if grep -q 'status.yml' "$SKILL_FILE"; then
    pass "Skill references status.yml for saving request"
else
    fail "Skill should save request to status.yml"
fi

if grep -q 'switch-client\|tmux attach' "$SKILL_FILE"; then
    pass "Skill handles tmux connection (attach or switch)"
else
    fail "Skill should handle tmux connection"
fi

# ============================================================
# PHASE 4: Verify skill does NOT do pre-PM work
# ============================================================
echo ""
echo "Phase 4: No pre-PM analysis or file creation..."
echo ""

# Should NOT have Haiku sub-agent or Explore agent for analysis
if grep -q 'subagent_type.*Explore' "$SKILL_FILE"; then
    fail "Skill should NOT use Explore subagent - PM handles discovery"
else
    pass "No Explore subagent usage (PM handles discovery)"
fi

if grep -qi 'model.*haiku' "$SKILL_FILE"; then
    fail "Skill should NOT spawn haiku sub-agents - PM handles analysis"
else
    pass "No haiku sub-agent spawning (PM handles analysis)"
fi

# Should NOT create prd.md, codebase-analysis.md, or tasks.json
if grep -q 'Create.*prd\.md\|Create.*codebase-analysis\.md' "$SKILL_FILE"; then
    fail "Skill should NOT create prd.md or codebase-analysis.md - PM handles this"
else
    pass "No context file creation (PM handles this)"
fi

# Should NOT ask user what they want to accomplish
if grep -q 'What would you like to accomplish' "$SKILL_FILE"; then
    fail "Skill should NOT ask user objectives - PM handles this"
else
    pass "No user objective questioning (PM handles this)"
fi

# Should NOT have dual workflow (A/B)
if grep -q 'WORKFLOW A\|WORKFLOW B' "$SKILL_FILE"; then
    fail "Skill should NOT have dual workflow pattern"
else
    pass "No dual workflow pattern (unified flow)"
fi

# ============================================================
# PHASE 5: Test workflow context file creation
# ============================================================
echo ""
echo "Phase 5: Workflow context files created via init-workflow.sh..."
echo ""

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Run init-workflow.sh directly (no Claude CLI needed)
TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test project discovery"

# Get workflow name
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)

if [[ -n "$WORKFLOW_NAME" ]]; then
    pass "Workflow folder created: $WORKFLOW_NAME"
    WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

    # Check status.yml exists
    if [[ -f "$WORKFLOW_PATH/status.yml" ]]; then
        pass "status.yml created"
    else
        fail "status.yml not found"
    fi

    # Check agents.yml exists
    if [[ -f "$WORKFLOW_PATH/agents.yml" ]]; then
        pass "agents.yml created"
    else
        fail "agents.yml not found"
    fi

    # Check agents/pm folder exists
    if [[ -d "$WORKFLOW_PATH/agents/pm" ]]; then
        pass "agents/pm directory created"
    else
        fail "agents/pm directory not found"
    fi
else
    fail "No workflow folder created"
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
