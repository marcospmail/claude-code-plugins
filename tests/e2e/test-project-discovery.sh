#!/bin/bash
# test-project-discovery.sh
#
# E2E Test: Project Discovery in yato-existing-project Skill
#
# Verifies that:
# 1. The skill uses LLM (Explore agent) for project discovery instead of bash scripts
# 2. The skill does NOT contain redundant project type detection bash commands
# 3. The skill instructs using Task tool with Explore agent for codebase analysis
# 4. The workflow creates proper context files

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="project-discovery"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Project Discovery in yato-existing-project        ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Project root: $PROJECT_ROOT"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup test environment
mkdir -p "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

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
# These are redundant because Explore agent handles discovery

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
# PHASE 3: Verify Explore agent is used for discovery
# ============================================================
echo ""
echo "Phase 3: Explore agent usage for discovery..."
echo ""

if grep -q 'subagent_type.*Explore' "$SKILL_FILE"; then
    pass "Skill instructs using Explore subagent"
else
    fail "Skill should use Task tool with subagent_type: Explore"
fi

if grep -qi 'haiku' "$SKILL_FILE"; then
    pass "Skill mentions haiku model for efficiency"
else
    fail "Skill should use haiku model for Explore agent"
fi

if grep -qi 'Targeted.*analysis\|codebase.*analysis\|Analyze.*codebase' "$SKILL_FILE"; then
    pass "Skill mentions targeted codebase analysis"
else
    fail "Skill should mention targeted codebase analysis"
fi

# ============================================================
# PHASE 4: Verify context file templates are defined
# ============================================================
echo ""
echo "Phase 4: Context file templates..."
echo ""

if grep -q 'prd.md' "$SKILL_FILE"; then
    pass "Skill mentions prd.md creation"
else
    fail "Skill should create prd.md"
fi

if grep -q 'codebase-analysis.md' "$SKILL_FILE"; then
    pass "Skill mentions codebase-analysis.md creation"
else
    fail "Skill should create codebase-analysis.md"
fi

if grep -q 'tasks.json' "$SKILL_FILE"; then
    pass "Skill mentions tasks.json creation"
else
    fail "Skill should create tasks.json"
fi

# ============================================================
# PHASE 5: Test actual workflow context file creation
# ============================================================
echo ""
echo "Phase 5: Workflow context files created by init-workflow.sh..."
echo ""

# Create a test project
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# Run init-workflow.sh via tmux
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test project discovery'" Enter
sleep 3

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
echo "╔══════════════════════════════════════════════════════════════╗"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)                                  ║"
    EXIT_CODE=0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                   ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
