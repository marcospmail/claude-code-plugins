#!/bin/bash
# E2E Test: constraints.md creation
#
# Verifies that:
# 1. PM gets constraints.md (not constraints.example.md)
# 2. PM constraints.md contains "cannot modify any code"
# 3. Other agents get constraints.md file
# 4. No constraints.example.md files are created
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

# Note: Don't use set -e as test failures should be counted, not exit immediately

# Test setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-constraints-$TEST_ID"
SESSION_NAME="e2e-constraints-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# ============================================================
# Setup
# ============================================================

echo "======================================================================"
echo "  E2E Test: constraints.md Creation"
echo "======================================================================"
echo ""
echo "  Test directory: $TEST_DIR"
echo ""

mkdir -p "$TEST_DIR"

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
for _retry in $(seq 1 5); do
    tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null && break
    sleep 1
    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
done

# Initialize git repo (needed for some operations)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "git init -q && git config user.name Test && git config user.email test@test.com" Enter
sleep 2

# Start Claude in the session
# Unset CLAUDECODE to allow nested Claude launch (when test runs from within Claude Code)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "unset CLAUDECODE && claude" Enter

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

# ============================================================
# Test 1: Create workflow and check PM constraints.md
# ============================================================

echo "Test 1: Creating workflow and checking PM constraints.md..."

# Create a workflow directory with PM agent
mkdir -p "$TEST_DIR/.workflow/001-test-constraints"
cat > "$TEST_DIR/.workflow/001-test-constraints/status.yml" << EOF
status: in-progress
session: $SESSION_NAME
EOF
echo "001-test-constraints" > "$TEST_DIR/.workflow/current"

# Ask Claude to create a PM agent using agent_manager
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && WORKFLOW_NAME=001-test-constraints uv run python $PROJECT_ROOT/lib/agent_manager.py init-files pm pm -p $TEST_DIR 2>&1 && echo 'PM_INIT_DONE'"
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

WORKFLOW_DIR="$TEST_DIR/.workflow/001-test-constraints"
PM_CONSTRAINTS="$WORKFLOW_DIR/agents/pm/constraints.md"

if [[ -f "$PM_CONSTRAINTS" ]]; then
    pass "PM constraints.md exists"
else
    fail "PM constraints.md not found at $PM_CONSTRAINTS"
fi

# ============================================================
# Test 2: PM constraints.md contains code modification rule
# ============================================================

echo ""
echo "Test 2: Checking PM constraints.md content..."

if grep -qi "cannot modify.*code\|cannot write.*code\|do not.*modify.*code" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "PM constraints.md contains code modification restriction"
else
    fail "PM constraints.md missing code modification restriction"
fi

# ============================================================
# Test 2b: PM constraints.md contains cancel-checkin prohibition
# ============================================================

echo ""
echo "Test 2b: Checking PM constraints.md cancel-checkin prohibition..."

if grep -qi "never.*cancel-checkin\|cannot.*cancel-checkin" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "PM constraints.md contains cancel-checkin prohibition"
else
    fail "PM constraints.md missing cancel-checkin prohibition"
fi

# ============================================================
# Test 3: No constraints.example.md for PM
# ============================================================

echo ""
echo "Test 3: Checking no constraints.example.md for PM..."

PM_EXAMPLE="$WORKFLOW_DIR/agents/pm/constraints.example.md"
if [[ ! -f "$PM_EXAMPLE" ]]; then
    pass "No constraints.example.md for PM (correct)"
else
    fail "constraints.example.md exists for PM (should not exist)"
fi

# ============================================================
# Test 4: Create developer agent and check constraints.md
# ============================================================

echo ""
echo "Test 4: Creating developer agent and checking constraints.md..."

# Ask Claude to create a developer agent
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && WORKFLOW_NAME=001-test-constraints uv run python $PROJECT_ROOT/lib/agent_manager.py init-files dev developer -p $TEST_DIR 2>&1 && echo 'DEV_INIT_DONE'"
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

DEV_CONSTRAINTS="$WORKFLOW_DIR/agents/dev/constraints.md"
if [[ -f "$DEV_CONSTRAINTS" ]]; then
    pass "Developer constraints.md exists"
else
    fail "Developer constraints.md not found"
fi

# ============================================================
# Test 5: No constraints.example.md for developer
# ============================================================

echo ""
echo "Test 5: Checking no constraints.example.md for developer..."

DEV_EXAMPLE="$WORKFLOW_DIR/agents/dev/constraints.example.md"
if [[ ! -f "$DEV_EXAMPLE" ]]; then
    pass "No constraints.example.md for developer (correct)"
else
    fail "constraints.example.md exists for developer (should not exist)"
fi

# ============================================================
# Test 6: Developer constraints.md is customizable
# ============================================================

echo ""
echo "Test 6: Checking developer constraints.md is customizable..."

if grep -q "# Add project-specific constraints\|# Examples:" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Developer constraints.md has customization hints"
else
    fail "Developer constraints.md missing customization hints"
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
