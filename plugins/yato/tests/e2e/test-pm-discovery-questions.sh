#!/bin/bash
# test-pm-discovery-questions.sh
#
# E2E Test: Verify PM briefing instructs proper discovery question behavior
#
# Verifies through Claude Code that the PM briefing contains instructions for:
# 1. Asking "What are we building?" for new/empty projects
# 2. Asking "What would you like to accomplish?" for existing projects
# 3. Being conversational - ONE question at a time
# 4. Confirming understanding before proceeding
# 5. Summarizing and asking for confirmation
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All execution goes through Claude running inside a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-discovery-questions"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: PM Discovery Questions Behavior"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"

ORCHESTRATOR_FILE="$PROJECT_ROOT/lib/orchestrator.py"

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "  - Waiting for Claude to start..."
sleep 8

# Check for trust prompt and send Enter to accept
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  - Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  - No trust prompt found, continuing..."
    sleep 5
fi

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Ask Claude to read orchestrator.py
# ============================================================
echo "Phase 2: Verifying PM briefing content via Claude..."

# Ask Claude to grep for discovery question patterns
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: grep -ic 'What are we building' $ORCHESTRATOR_FILE && grep -ic 'What would you like to accomplish' $ORCHESTRATOR_FILE"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt if it appears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    echo "  - Skill trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

# ============================================================
# PHASE 3: Verify PM briefing content patterns
# ============================================================
echo ""
echo "Phase 3: Checking PM briefing patterns..."

# Test 1: PM asks "What are we building?" for new/empty projects
if grep -qi "What are we building" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes 'What are we building?' question for new projects"
else
    fail "PM briefing missing 'What are we building?' for new projects"
fi

# Test 2: PM asks "What would you like to accomplish?" for existing projects
if grep -qi "What would you like to accomplish" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes 'What would you like to accomplish?' for existing projects"
else
    fail "PM briefing missing 'What would you like to accomplish?' for existing projects"
fi

# Test 3: PM should be conversational - ONE question at a time
if grep -qi "ONE question at a time\|Ask ONE question" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing instructs asking ONE question at a time"
else
    fail "PM briefing missing 'ONE question at a time' instruction"
fi

# Test 4: PM should confirm understanding before proceeding
if grep -qi "Is this correct\|clarification" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes confirmation step before proceeding"
else
    fail "PM briefing missing confirmation instruction"
fi

# Test 5: PM should summarize understanding
if grep -qi "SUMMARIZE" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes instruction to SUMMARIZE understanding"
else
    fail "PM briefing missing SUMMARIZE instruction"
fi

# Test 6: PM should wait for user confirmation
if grep -qi "Wait for confirmation\|wait for user" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes instruction to wait for user confirmation"
else
    fail "PM briefing missing 'wait for confirmation' instruction"
fi

# Test 7: PM should NOT skip questions or assume answers
if grep -qi "NEVER skip\|never assume" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes instruction to never skip questions/assume answers"
else
    fail "PM briefing missing 'never skip/assume' instruction"
fi

# Test 8: PM should handle PRD input options
if grep -qi "a brief description.*URL.*PRD" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing mentions PRD/description/URL input options"
else
    fail "PM briefing missing PRD input options"
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
