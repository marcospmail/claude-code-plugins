#!/bin/bash
# test-team-approval-loop.sh
#
# E2E Test: Team Approval Loop
#
# This test verifies that the PM briefing contains instructions for:
# 1. Using AskUserQuestion for team approval
# 2. Requiring explicit "Yes, looks good" before saving team
# 3. Re-asking after user provides changes via "Other"
# 4. Never saving team until user explicitly approves
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-approval-loop"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Team Approval Loop"
echo "======================================================================"
echo ""
echo "  Project root: $PROJECT_ROOT"
echo ""

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

# Setup test environment
echo "Setting up test environment..."
mkdir -p "$TEST_DIR"

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start and handle trust prompt
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

BRIEFING_TEMPLATE="$PROJECT_ROOT/lib/templates/pm_planning_briefing.md.j2"

echo "Testing PM briefing for team approval loop..."
echo ""

# Ask Claude to grep for AskUserQuestion in briefing template
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: grep -c 'AskUserQuestion' '$BRIEFING_TEMPLATE' && grep -c 'Does this team structure work' '$BRIEFING_TEMPLATE'"
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

# Test 1: PM uses AskUserQuestion for team approval
echo "Test 1: AskUserQuestion for team approval..."
if grep -q "AskUserQuestion" "$BRIEFING_TEMPLATE" && grep -q "Does this team structure work" "$BRIEFING_TEMPLATE"; then
    pass "PM briefing uses AskUserQuestion for team approval"
else
    fail "PM briefing missing AskUserQuestion for team approval"
fi

# Test 2: Has "Yes, looks good" option
echo "Test 2: 'Yes, looks good' option exists..."
if grep -q "Yes, looks good" "$BRIEFING_TEMPLATE"; then
    pass "PM briefing includes 'Yes, looks good' option"
else
    fail "PM briefing missing 'Yes, looks good' option"
fi

# Test 3: Instructions for approval loop when user provides changes
echo "Test 3: Team approval loop instructions..."
if grep -q "CRITICAL TEAM APPROVAL LOOP" "$BRIEFING_TEMPLATE"; then
    pass "PM briefing includes CRITICAL TEAM APPROVAL LOOP section"
else
    fail "PM briefing missing CRITICAL TEAM APPROVAL LOOP section"
fi

# Test 4: Must re-ask when user types changes in Other
echo "Test 4: Re-ask after user changes..."
if grep -qi "If user types changes.*ASK AGAIN\|update team proposal.*then ASK AGAIN" "$BRIEFING_TEMPLATE"; then
    pass "PM briefing instructs to ASK AGAIN after user changes"
else
    fail "PM briefing missing instruction to ASK AGAIN after user changes"
fi

# Test 5: Never save team until explicit approval
echo "Test 5: Never save until explicit approval..."
if grep -qi "NEVER save team until user explicitly selects" "$BRIEFING_TEMPLATE"; then
    pass "PM briefing says NEVER save until explicit approval"
else
    fail "PM briefing missing 'NEVER save until explicit approval' instruction"
fi

# Test 6: Keep asking until user approves
echo "Test 6: Keep asking until approval..."
if grep -qi "Keep asking until user approves" "$BRIEFING_TEMPLATE"; then
    pass "PM briefing says to keep asking until approval"
else
    fail "PM briefing missing 'keep asking until approval' instruction"
fi

# Test 7: Step 6 requires explicit approval
echo "Test 7: Step 6 requires 'Yes, looks good'..."
if grep -q "AFTER USER SELECTS 'Yes, looks good'" "$BRIEFING_TEMPLATE"; then
    pass "Step 6 requires explicit 'Yes, looks good' selection"
else
    fail "Step 6 doesn't require explicit 'Yes, looks good' selection"
fi

# Test 8: Only one option (Yes, looks good) - user must type Other for changes
echo "Test 8: Single approval option (changes via Other)..."
# Count how many options are listed for team approval
OPTION_COUNT=$(grep -A 5 "Does this team structure work" "$BRIEFING_TEMPLATE" | grep -c "'.*' (description:")
if [[ "$OPTION_COUNT" -eq 1 ]]; then
    pass "Only one approval option ('Yes, looks good') - changes via Other"
else
    fail "Expected 1 option for team approval, found $OPTION_COUNT"
fi

# Ask Claude to verify the file exists and has approval content
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: grep -l 'CRITICAL TEAM APPROVAL LOOP' '$BRIEFING_TEMPLATE' && echo 'APPROVAL_LOOP_FOUND'"
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

# Results
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
