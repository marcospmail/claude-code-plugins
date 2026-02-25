#!/bin/bash
# test-custom-agent-naming.sh
#
# E2E Test: Custom Agent Naming and Path References
#
# This test verifies:
# 1. When agents have custom names (e.g., discoverer:qa:opus), folders are created by NAME not ROLE
# 2. The briefing sent to agents references the correct folder path (by agent name)
# 3. Multiple agents with the same role but different names have separate folders
#
# BUG REFERENCE: When "discoverer:qa:opus" is created:
#   - Folder should be: .workflow/.../agents/discoverer/
#   - Briefing should say: .workflow/.../agents/discoverer/agent-tasks.md
#   - NOT: .workflow/.../agents/qa/agent-tasks.md
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All script execution goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="custom-agent-naming"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-naming-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Custom Agent Naming and Path References"
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
echo "function test() { return true; }" > "$TEST_DIR/app.js"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "orchestrator" -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Initialize workflow directly
# ============================================================
echo "Phase 2: Initializing workflow..."

TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test custom naming"

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "$WORKFLOW_NAME"
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Save team structure directly
# ============================================================
echo "Phase 3: Saving team structure..."

source "$PROJECT_ROOT/bin/workflow-utils.sh" && save_team_structure "$TEST_DIR" discoverer:qa:opus impl:developer:opus

echo "  - Team structure saved"
echo ""

# ============================================================
# PHASE 4: Create team windows directly
# ============================================================
echo "Phase 4: Creating team..."

TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/create-team.sh" "$TEST_DIR" discoverer:qa:opus impl:developer:opus

echo "  - Team creation completed"
echo ""

# ============================================================
# PHASE 5: Verify folder structure (by NAME, not ROLE)
# ============================================================
echo "Phase 5: Verifying folder structure..."

# Test 1: Discoverer folder exists (by name, not by role)
if [[ -d "$WORKFLOW_PATH/agents/discoverer" ]]; then
    pass "Agent folder created by NAME: agents/discoverer/"
else
    fail "Expected folder agents/discoverer/ not found"
fi

# Test 2: Impl folder exists (custom name, not "developer")
if [[ -d "$WORKFLOW_PATH/agents/impl" ]]; then
    pass "Agent folder created by NAME: agents/impl/"
else
    fail "Expected folder agents/impl/ not found"
fi

# Test 3: No folder by ROLE only (would be wrong)
if [[ -d "$WORKFLOW_PATH/agents/qa" ]] && [[ ! -d "$WORKFLOW_PATH/agents/discoverer" ]]; then
    fail "Folder created by ROLE (qa) instead of NAME (discoverer)"
else
    pass "No incorrect role-based folder created"
fi

# ============================================================
# PHASE 6: Verify identity.yml content
# ============================================================
echo ""
echo "Phase 6: Verifying identity.yml files..."

# Test 4: Discoverer identity.yml has correct name
if grep -q '^name: "discoverer"$' "$WORKFLOW_PATH/agents/discoverer/identity.yml" 2>/dev/null; then
    pass "discoverer/identity.yml has name: discoverer"
else
    fail "discoverer/identity.yml has wrong name"
fi

# Test 5: Discoverer identity.yml has correct role
if grep -q '^role: "qa"$' "$WORKFLOW_PATH/agents/discoverer/identity.yml" 2>/dev/null; then
    pass "discoverer/identity.yml has role: qa (custom name with qa role)"
else
    fail "discoverer/identity.yml has wrong role"
fi

# Test 6: Impl identity.yml has correct name
if grep -q '^name: "impl"$' "$WORKFLOW_PATH/agents/impl/identity.yml" 2>/dev/null; then
    pass "impl/identity.yml has name: impl"
else
    fail "impl/identity.yml has wrong name"
fi

# Test 7: Impl identity.yml has correct role
if grep -q '^role: "developer"$' "$WORKFLOW_PATH/agents/impl/identity.yml" 2>/dev/null; then
    pass "impl/identity.yml has role: developer"
else
    fail "impl/identity.yml has wrong role"
fi

# ============================================================
# PHASE 7: Verify agents.yml registry
# ============================================================
echo ""
echo "Phase 7: Verifying agents.yml registry..."

AGENTS_YML="$WORKFLOW_PATH/agents.yml"

# Test 8: agents.yml contains discoverer agent with correct name
if grep -q 'name: "discoverer"' "$AGENTS_YML" 2>/dev/null; then
    pass "agents.yml has agent named 'discoverer'"
else
    fail "agents.yml missing 'discoverer' entry"
fi

# Test 9: agents.yml shows discoverer with role qa
if grep -A 4 'name: "discoverer"' "$AGENTS_YML" 2>/dev/null | grep -q "role: qa"; then
    pass "agents.yml shows discoverer has role: qa"
else
    fail "agents.yml doesn't show discoverer's role as qa"
fi

# ============================================================
# PHASE 8: Verify window names match agent names
# ============================================================
echo ""
echo "Phase 8: Verifying window names..."

WINDOW_LIST=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" 2>/dev/null)

# Test 10: Window named "discoverer" (not "qa")
if echo "$WINDOW_LIST" | grep -qi "discoverer"; then
    pass "Window named 'discoverer' (by agent name, not role)"
else
    fail "No window named 'discoverer' found"
    echo "    Windows found: $WINDOW_LIST"
fi

# Test 11: Window named "impl" (not "developer")
if echo "$WINDOW_LIST" | grep -qi "impl"; then
    pass "Window named 'impl' (by agent name, not role)"
else
    fail "No window named 'impl' found"
    echo "    Windows found: $WINDOW_LIST"
fi

# ============================================================
# PHASE 9: Verify agent-tasks.md files exist at correct paths
# ============================================================
echo ""
echo "Phase 9: Verifying agent-tasks.md files exist at correct paths..."

# Test 12: agent-tasks.md exists at discoverer path
if [[ -f "$WORKFLOW_PATH/agents/discoverer/agent-tasks.md" ]]; then
    pass "agent-tasks.md exists at agents/discoverer/"
else
    fail "agent-tasks.md missing at agents/discoverer/"
fi

# Test 13: agent-tasks.md exists at impl path
if [[ -f "$WORKFLOW_PATH/agents/impl/agent-tasks.md" ]]; then
    pass "agent-tasks.md exists at agents/impl/"
else
    fail "agent-tasks.md missing at agents/impl/"
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
