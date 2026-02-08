#!/bin/bash
# test-qa-test-file-permissions.sh
#
# E2E Test: QA Agent Test File Permissions
#
# BUG 8 REGRESSION TEST
#
# This test verifies:
# 1. QA agent identity.yml has can_modify_code: test-only
# 2. QA instructions explicitly state they CAN modify test files
# 3. QA instructions list test file directories (e2e/, tests/, __tests__/)
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="qa-test-permissions"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-qa-perms-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: QA Test File Permissions (BUG 8)"
echo "======================================================================"
echo ""
echo "  Test directory: $TEST_DIR"
echo ""

# Track test results
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Phase 1: Setup and create QA agent via Claude
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

echo "  Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  No trust prompt found, continuing..."
    sleep 5
fi

echo "  Test environment ready"
echo ""

# Ask Claude to create a workflow and QA agent
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && uv run python $PROJECT_ROOT/lib/agent_manager.py create $SESSION_NAME qa -p $TEST_DIR 2>&1 && echo 'AGENT_CREATE_DONE'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

# Find the workflow directory
WORKFLOW_DIR=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1)

# If no workflow dir exists, create one manually and run agent_manager
if [[ -z "$WORKFLOW_DIR" ]]; then
    echo "  No workflow found, creating manually..."
    mkdir -p "$TEST_DIR/.workflow/001-test-qa"
    cat > "$TEST_DIR/.workflow/001-test-qa/status.yml" << EOF
status: in-progress
session: $SESSION_NAME
EOF
    echo "001-test-qa" > "$TEST_DIR/.workflow/current"

    # Ask Claude to create agent with explicit workflow
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && WORKFLOW_NAME=001-test-qa uv run python $PROJECT_ROOT/lib/agent_manager.py create $SESSION_NAME qa -p $TEST_DIR 2>&1 && echo 'AGENT_CREATE_DONE2'"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 10

    SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
    if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
        tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
        sleep 20
    else
        sleep 20
    fi

    WORKFLOW_DIR="$TEST_DIR/.workflow/001-test-qa"
fi

WORKFLOW_NAME=$(basename "$WORKFLOW_DIR" 2>/dev/null)
echo "  Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# Phase 2: Verify identity.yml can_modify_code value
# ============================================================
echo "Phase 2: Checking QA identity.yml..."

QA_IDENTITY="$WORKFLOW_DIR/agents/qa/identity.yml"

# Test 1: identity.yml exists
if [[ -f "$QA_IDENTITY" ]]; then
    pass "QA identity.yml exists"
else
    fail "QA identity.yml not found at $QA_IDENTITY"
    # Try alternate paths
    ALT_IDENTITY=$(find "$TEST_DIR/.workflow" -name "identity.yml" -path "*/qa/*" 2>/dev/null | head -1)
    if [[ -n "$ALT_IDENTITY" ]]; then
        echo "  Found at: $ALT_IDENTITY"
        QA_IDENTITY="$ALT_IDENTITY"
    fi
fi

# Test 2: can_modify_code is "test-only" (not false)
if [[ -f "$QA_IDENTITY" ]]; then
    if grep -q "^can_modify_code: test-only$" "$QA_IDENTITY" 2>/dev/null; then
        pass "QA identity.yml has can_modify_code: test-only"
    else
        CAN_MODIFY=$(grep "can_modify_code:" "$QA_IDENTITY" 2>/dev/null)
        fail "QA identity.yml has wrong can_modify_code: $CAN_MODIFY"
    fi
fi

echo ""

# ============================================================
# Phase 3: Verify QA instructions clarify test file permissions
# ============================================================
echo "Phase 3: Checking QA instructions..."

QA_INSTRUCTIONS="$WORKFLOW_DIR/agents/qa/instructions.md"

# Test 3: Instructions exist
if [[ -f "$QA_INSTRUCTIONS" ]]; then
    pass "QA instructions.md exists"
else
    fail "QA instructions.md not found"
    ALT_INSTRUCTIONS=$(find "$TEST_DIR/.workflow" -name "instructions.md" -path "*/qa/*" 2>/dev/null | head -1)
    if [[ -n "$ALT_INSTRUCTIONS" ]]; then
        echo "  Found at: $ALT_INSTRUCTIONS"
        QA_INSTRUCTIONS="$ALT_INSTRUCTIONS"
    fi
fi

if [[ -f "$QA_INSTRUCTIONS" ]]; then
    # Test 4: Instructions mention test files CAN be modified
    if grep -qi "can.*modify.*test\|can.*write.*test\|allowed.*test" "$QA_INSTRUCTIONS" 2>/dev/null; then
        pass "QA instructions say test files CAN be modified"
    else
        fail "QA instructions don't clarify test file permissions"
    fi

    # Test 5: Instructions mention e2e/ directory
    if grep -q "e2e/" "$QA_INSTRUCTIONS" 2>/dev/null; then
        pass "QA instructions mention e2e/ directory"
    else
        fail "QA instructions don't mention e2e/ directory"
    fi

    # Test 6: Instructions mention tests/ directory
    if grep -q "tests/" "$QA_INSTRUCTIONS" 2>/dev/null; then
        pass "QA instructions mention tests/ directory"
    else
        fail "QA instructions don't mention tests/ directory"
    fi

    # Test 7: Instructions mention what directories are OFF-LIMITS
    if grep -qi "src/\|lib/\|production\|cannot.*modify" "$QA_INSTRUCTIONS" 2>/dev/null; then
        pass "QA instructions mention production code restrictions"
    else
        fail "QA instructions don't clarify production code restrictions"
    fi

    # Test 8: Description mentions test files
    if grep -qi "CAN write.*test\|CAN.*modify.*TEST" "$QA_INSTRUCTIONS" 2>/dev/null; then
        pass "QA role description mentions test file permissions"
    else
        fail "QA role description doesn't mention test file permissions"
    fi
fi

echo ""

# ============================================================
# Phase 4: Verify agent_manager template
# ============================================================
echo "Phase 4: Checking agent_manager.py template..."

AGENT_MANAGER="$PROJECT_ROOT/lib/agent_manager.py"

# Ask Claude to check the template
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: grep -A 2 'qa' '$AGENT_MANAGER' | grep -c 'test-only' && echo 'TEMPLATE_CHECK_DONE'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

# Check the template files for QA role with test-only
QA_IDENTITY_TEMPLATE="$PROJECT_ROOT/lib/templates/agent_identity.yml.j2"
if [[ -f "$QA_IDENTITY_TEMPLATE" ]]; then
    if grep -q "test-only" "$QA_IDENTITY_TEMPLATE" 2>/dev/null; then
        pass "Identity template has test-only for QA role"
    else
        fail "Identity template missing test-only for QA"
    fi
elif grep -q "test-only" "$AGENT_MANAGER" 2>/dev/null; then
    pass "agent_manager.py sets QA can_modify_code to test-only"
else
    fail "agent_manager.py doesn't set QA can_modify_code correctly"
fi

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
