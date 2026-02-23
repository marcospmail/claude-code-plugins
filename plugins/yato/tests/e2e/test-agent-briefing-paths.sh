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
#
# Tests init-workflow.sh and save_team_structure directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-briefing-paths"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-briefing-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Agent Briefing Uses NAME Not ROLE (BUG 1)"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
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
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "orchestrator" -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Initialize workflow
# ============================================================
echo "Phase 2: Initializing workflow..."

TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test briefing paths"

# Get workflow name
WORKFLOW_NAME=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1 | xargs basename)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Save team structure with custom names
# ============================================================
echo "Phase 3: Creating team with custom agent names..."

source "$PROJECT_ROOT/bin/workflow-utils.sh"
save_team_structure "$TEST_DIR" "discoverer:qa:opus"

echo "  - Team structure saved"
echo ""

# ============================================================
# PHASE 4: Verify agent folder created by NAME
# ============================================================
echo "Phase 4: Verifying agent folder structure..."

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
# PHASE 5: Verify briefing script logic (static checks)
# ============================================================
echo "Phase 5: Verifying create-agent.sh briefing path logic..."

# Test 5: Verify the briefing template in create-agent.sh uses AGENT_NAME_FOR_PATH
if grep -q 'agents/\$AGENT_NAME_FOR_PATH/agent-tasks.md' "$PROJECT_ROOT/bin/create-agent.sh" 2>/dev/null; then
    pass "create-agent.sh uses \$AGENT_NAME_FOR_PATH for task file path"
else
    fail "create-agent.sh still using wrong variable for task file path"
fi

# Test 6: Verify briefing template uses AGENT_NAME_FOR_PATH for identity.yml
if grep -q 'agents/\$AGENT_NAME_FOR_PATH/identity.yml' "$PROJECT_ROOT/bin/create-agent.sh" 2>/dev/null; then
    pass "create-agent.sh uses \$AGENT_NAME_FOR_PATH for identity path"
else
    fail "create-agent.sh still using wrong variable for identity path"
fi

# Test 7: Verify briefing template uses AGENT_NAME_FOR_PATH for notify-pm message
if grep -q 'from \$AGENT_NAME_FOR_PATH' "$PROJECT_ROOT/bin/create-agent.sh" 2>/dev/null; then
    pass "create-agent.sh uses \$AGENT_NAME_FOR_PATH in notify-pm message"
else
    fail "create-agent.sh still using wrong variable for notify-pm"
fi

echo ""

# ============================================================
# PHASE 6: Verify agents.yml structure
# ============================================================
echo "Phase 6: Verifying agents.yml structure..."

# Test 8: agents.yml has discoverer entry
if grep -q "name: discoverer$" "$WORKFLOW_PATH/agents.yml" 2>/dev/null; then
    pass "agents.yml has agent: discoverer"
else
    fail "agents.yml missing discoverer"
fi

# Test 9: agents.yml shows qa role for discoverer
if grep -A 4 "name: discoverer$" "$WORKFLOW_PATH/agents.yml" 2>/dev/null | grep -q "role: qa"; then
    pass "agents.yml shows discoverer role: qa"
else
    fail "agents.yml has wrong role for discoverer"
fi

# Test 10: No team.yml file created (replaced by agents.yml)
if [[ -f "$WORKFLOW_PATH/team.yml" ]]; then
    fail "team.yml exists (should not be created, agents.yml is the single source)"
else
    pass "No team.yml file created (agents.yml is single source of truth)"
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
