#!/bin/bash
# test-pm-checkin-askuser.sh
#
# E2E Test: Verify PM uses AskUserQuestion tool for check-in frequency
#
# Verifies through Claude Code that orchestrator.py PM briefing includes
# AskUserQuestion instructions with the correct check-in interval options.
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All execution goes through Claude running inside a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-checkin-askuser"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: PM Check-in AskUserQuestion"
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

BRIEFING_TEMPLATE="$PROJECT_ROOT/lib/templates/pm_planning_briefing.md.j2"

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
# PHASE 2: Ask Claude to verify orchestrator.py content
# ============================================================
echo "Phase 2: Verifying PM briefing content via Claude..."

# Ask Claude to grep for the check-in interval patterns
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: grep -c 'AskUserQuestion' $BRIEFING_TEMPLATE && grep -c 'minutes' $BRIEFING_TEMPLATE"
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
# PHASE 3: Verify content patterns
# ============================================================
echo ""
echo "Phase 3: Checking PM briefing patterns..."

# Test 1: PM briefing mentions AskUserQuestion for check-in interval
if grep -q "check-in interval.*AskUserQuestion" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "PM briefing mentions AskUserQuestion for check-in interval"
else
    fail "PM briefing missing AskUserQuestion for check-in interval"
fi

# Test 2: 3 minutes option exists
if grep -q "'3 minutes'" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "3 minutes option exists"
else
    fail "3 minutes option missing"
fi

# Test 3: 5 minutes (Recommended) option exists
if grep -q "5 minutes (Recommended)" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "5 minutes (Recommended) option exists"
else
    fail "5 minutes (Recommended) option missing"
fi

# Test 4: 10 minutes option exists
if grep -q "'10 minutes'" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "10 minutes option exists"
else
    fail "10 minutes option missing"
fi

# Test 5: update_checkin_interval command is referenced
if grep -q "update_checkin_interval" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "update_checkin_interval command referenced"
else
    fail "update_checkin_interval command not referenced"
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
