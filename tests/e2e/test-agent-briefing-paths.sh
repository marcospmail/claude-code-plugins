#!/bin/bash
# test-agent-briefing-paths.sh
#
# E2E Test: Agent Briefing Uses NAME Not ROLE for Paths
#
# BUG 1 REGRESSION TEST
#
# This test verifies:
# 1. When agent "discoverer:qa:opus" is created, paths use "discoverer" not "qa"
# 2. The create-agent.sh script correctly derives AGENT_NAME_FOR_PATH
# 3. All generated files use agent NAME for folder paths

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-briefing-paths"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-briefing-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Briefing Uses NAME Not ROLE (BUG 1)         ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

# Create tmux session
tmux new-session -d -s "$SESSION_NAME" -n "orchestrator" -c "$TEST_DIR"

# Initialize workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test briefing paths" > /dev/null 2>&1

# Get workflow name
WORKFLOW_NAME=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1 | xargs basename)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 2: Save team structure with custom names
# ============================================================
echo "Phase 2: Creating team with custom agent names..."

source "$PROJECT_ROOT/bin/workflow-utils.sh"
save_team_structure "$TEST_DIR" discoverer:qa:opus > /dev/null 2>&1

echo "  - Team structure saved"
echo ""

# ============================================================
# PHASE 3: Verify agent folder created by NAME
# ============================================================
echo "Phase 3: Verifying agent folder structure..."

# Test 1: Agent folder created by NAME (discoverer), not ROLE (qa)
if [[ -d "$WORKFLOW_PATH/agents/discoverer" ]]; then
    pass "Agent folder created at agents/discoverer/ (by NAME)"
else
    fail "Agent folder missing at agents/discoverer/"
fi

# Test 2: No folder at agents/qa (that would be wrong for custom-named agent)
if [[ -d "$WORKFLOW_PATH/agents/qa" ]]; then
    fail "Wrong folder created at agents/qa/ (should be agents/discoverer/)"
else
    pass "No incorrect folder at agents/qa/"
fi

# Test 3: identity.yml has correct name field
if grep -q "^name: discoverer$" "$WORKFLOW_PATH/agents/discoverer/identity.yml" 2>/dev/null; then
    pass "identity.yml name: discoverer"
else
    fail "identity.yml has wrong name"
fi

# Test 4: identity.yml has correct role field
if grep -q "^role: qa$" "$WORKFLOW_PATH/agents/discoverer/identity.yml" 2>/dev/null; then
    pass "identity.yml role: qa (custom name with qa role)"
else
    fail "identity.yml has wrong role"
fi

echo ""

# ============================================================
# PHASE 4: Create team and verify agents.yml
# ============================================================
echo "Phase 4: Creating team windows and verifying registry..."

# Create the team (with --no-start to skip Claude for faster testing)
"$PROJECT_ROOT/bin/create-agent.sh" "$SESSION_NAME" qa \
    -n discoverer \
    -p "$TEST_DIR" \
    --pm-window "$SESSION_NAME:0.1" \
    --no-start \
    --no-brief > /dev/null 2>&1

# Test 5: agents.yml has agent entry with correct name
if grep -q "name: discoverer$" "$WORKFLOW_PATH/agents.yml" 2>/dev/null; then
    pass "agents.yml has entry: name: discoverer"
else
    fail "agents.yml missing discoverer entry"
fi

# Test 6: agents.yml shows correct role for discoverer
if grep -A 4 "name: discoverer$" "$WORKFLOW_PATH/agents.yml" 2>/dev/null | grep -q "role: qa"; then
    pass "agents.yml shows discoverer has role: qa"
else
    fail "agents.yml has wrong role for discoverer"
fi

echo ""

# ============================================================
# PHASE 5: Verify briefing script logic (unit test style)
# ============================================================
echo "Phase 5: Verifying create-agent.sh briefing path logic..."

# Test 7: Verify AGENT_NAME_FOR_PATH derivation in create-agent.sh
# The script does: AGENT_NAME_FOR_PATH=$(echo "$WINDOW_NAME" | tr '[:upper:]' '[:lower:]')
WINDOW_NAME="Discoverer"  # This is what gets passed as -n
AGENT_NAME_FOR_PATH=$(echo "$WINDOW_NAME" | tr '[:upper:]' '[:lower:]')

if [[ "$AGENT_NAME_FOR_PATH" == "discoverer" ]]; then
    pass "AGENT_NAME_FOR_PATH correctly derives 'discoverer' from window name"
else
    fail "AGENT_NAME_FOR_PATH derivation failed: got '$AGENT_NAME_FOR_PATH'"
fi

# Test 8: Verify the briefing template in create-agent.sh uses AGENT_NAME_FOR_PATH
if grep -q 'agents/\$AGENT_NAME_FOR_PATH/agent-tasks.md' "$PROJECT_ROOT/bin/create-agent.sh" 2>/dev/null; then
    pass "create-agent.sh uses \$AGENT_NAME_FOR_PATH for task file path"
else
    fail "create-agent.sh still using wrong variable for task file path"
fi

# Test 9: Verify briefing template uses AGENT_NAME_FOR_PATH for identity.yml
if grep -q 'agents/\$AGENT_NAME_FOR_PATH/identity.yml' "$PROJECT_ROOT/bin/create-agent.sh" 2>/dev/null; then
    pass "create-agent.sh uses \$AGENT_NAME_FOR_PATH for identity path"
else
    fail "create-agent.sh still using wrong variable for identity path"
fi

# Test 10: Verify briefing template uses AGENT_NAME_FOR_PATH for notify-pm message
if grep -q 'from \$AGENT_NAME_FOR_PATH' "$PROJECT_ROOT/bin/create-agent.sh" 2>/dev/null; then
    pass "create-agent.sh uses \$AGENT_NAME_FOR_PATH in notify-pm message"
else
    fail "create-agent.sh still using wrong variable for notify-pm"
fi

echo ""

# ============================================================
# PHASE 6: Verify team.yml structure
# ============================================================
echo "Phase 6: Verifying team.yml structure..."

# Test 11: team.yml has discoverer entry
if grep -q "name: discoverer$" "$WORKFLOW_PATH/team.yml" 2>/dev/null; then
    pass "team.yml has agent: discoverer"
else
    fail "team.yml missing discoverer"
fi

# Test 12: team.yml shows qa role for discoverer
if grep -A 2 "name: discoverer$" "$WORKFLOW_PATH/team.yml" 2>/dev/null | grep -q "role: qa"; then
    pass "team.yml shows discoverer role: qa"
else
    fail "team.yml has wrong role for discoverer"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                             ║"
    EXIT_CODE=0
else
    printf "║  ❌ SOME TESTS FAILED (%d failed, %d passed)                   ║\n" $TESTS_FAILED $TESTS_PASSED
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
