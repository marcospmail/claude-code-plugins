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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-approval-loop"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Team Approval Loop                                ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup test environment
mkdir -p "$TEST_DIR"
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

ORCHESTRATOR_FILE="$PROJECT_ROOT/lib/orchestrator.py"

echo "Testing PM briefing for team approval loop..."
echo ""

# Test 1: PM uses AskUserQuestion for team approval
echo "Test 1: AskUserQuestion for team approval..."
if grep -q "AskUserQuestion" "$ORCHESTRATOR_FILE" && grep -q "Does this team structure work" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing uses AskUserQuestion for team approval"
else
    fail "PM briefing missing AskUserQuestion for team approval"
fi

# Test 2: Has "Yes, looks good" option
echo "Test 2: 'Yes, looks good' option exists..."
if grep -q "Yes, looks good" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes 'Yes, looks good' option"
else
    fail "PM briefing missing 'Yes, looks good' option"
fi

# Test 3: Instructions for approval loop when user provides changes
echo "Test 3: Team approval loop instructions..."
if grep -q "CRITICAL TEAM APPROVAL LOOP" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing includes CRITICAL TEAM APPROVAL LOOP section"
else
    fail "PM briefing missing CRITICAL TEAM APPROVAL LOOP section"
fi

# Test 4: Must re-ask when user types changes in Other
echo "Test 4: Re-ask after user changes..."
if grep -qi "If user types changes.*ASK AGAIN\|update team proposal.*then ASK AGAIN" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing instructs to ASK AGAIN after user changes"
else
    fail "PM briefing missing instruction to ASK AGAIN after user changes"
fi

# Test 5: Never save team until explicit approval
echo "Test 5: Never save until explicit approval..."
if grep -qi "NEVER save team until user explicitly selects" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing says NEVER save until explicit approval"
else
    fail "PM briefing missing 'NEVER save until explicit approval' instruction"
fi

# Test 6: Keep asking until user approves
echo "Test 6: Keep asking until approval..."
if grep -qi "Keep asking until user approves" "$ORCHESTRATOR_FILE"; then
    pass "PM briefing says to keep asking until approval"
else
    fail "PM briefing missing 'keep asking until approval' instruction"
fi

# Test 7: Step 6 requires explicit approval
echo "Test 7: Step 6 requires 'Yes, looks good'..."
if grep -q "AFTER USER SELECTS 'Yes, looks good'" "$ORCHESTRATOR_FILE"; then
    pass "Step 6 requires explicit 'Yes, looks good' selection"
else
    fail "Step 6 doesn't require explicit 'Yes, looks good' selection"
fi

# Test 8: Only one option (Yes, looks good) - user must type Other for changes
echo "Test 8: Single approval option (changes via Other)..."
# Count how many options are listed for team approval
OPTION_COUNT=$(grep -A 5 "Does this team structure work" "$ORCHESTRATOR_FILE" | grep -c "'.*' (description:")
if [[ "$OPTION_COUNT" -eq 1 ]]; then
    pass "Only one approval option ('Yes, looks good') - changes via Other"
else
    fail "Expected 1 option for team approval, found $OPTION_COUNT"
fi

# Results
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
