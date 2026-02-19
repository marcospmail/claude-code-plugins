#!/bin/bash
# test-team-suggestion-behavior.sh
#
# E2E Test: Team Suggestion Behavioral Test
#
# Verifies that the team suggestion system correctly maps task types to templates:
# - Development template has multi-agent team (developer, qa, code-reviewer, security-reviewer)
# - Bug template has minimal team (developer only)
# - PM briefing instructs PM to use AskUserQuestion with templates
# - Templates have use_cases that match request types
#
# Tests the code/config that drives PM behavior, not live AI output.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-suggestion-behavior"

echo "======================================================================"
echo "  E2E Test: Team Suggestion Behavioral Test"
echo "======================================================================"
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

TEMPLATES_DIR="$PROJECT_ROOT/templates/team-suggestions"
ORCH_FILE="$PROJECT_ROOT/lib/orchestrator.py"

# ============================================================
# SCENARIO 1: Development Template → Multi-Agent Team
# ============================================================
echo "Scenario 1: Development template (new feature request)"
echo "------------------------------------------------------"

DEV_TEMPLATE="$TEMPLATES_DIR/development.yml"

# Test 1: Development template has developer agent
if grep -q "role: developer" "$DEV_TEMPLATE" 2>/dev/null; then
    pass "Scenario 1: Development template includes developer agent"
else
    fail "Scenario 1: Development template missing developer agent"
fi

# Test 2: Development template has QA agent(s)
if grep -q "role: qa" "$DEV_TEMPLATE" 2>/dev/null; then
    pass "Scenario 1: Development template includes QA agent(s)"
else
    fail "Scenario 1: Development template missing QA agent(s)"
fi

# Test 3: Development template has code-reviewer
if grep -q "role: code-reviewer" "$DEV_TEMPLATE" 2>/dev/null; then
    pass "Scenario 1: Development template includes code-reviewer agent"
else
    fail "Scenario 1: Development template missing code-reviewer agent"
fi

# Test 4: Development template has security-reviewer
if grep -q "role: security-reviewer" "$DEV_TEMPLATE" 2>/dev/null; then
    pass "Scenario 1: Development template includes security-reviewer agent"
else
    fail "Scenario 1: Development template missing security-reviewer agent"
fi

# Test 5: Development template use_cases match feature requests
if grep -q "Adding a new feature\|Building a new module\|new API endpoint\|new UI pages" "$DEV_TEMPLATE" 2>/dev/null; then
    pass "Scenario 1: Development template use_cases match feature requests"
else
    fail "Scenario 1: Development template use_cases don't match feature requests"
fi

echo ""

# ============================================================
# SCENARIO 2: Bug Template → Minimal Team
# ============================================================
echo "Scenario 2: Bug template (bug fix request)"
echo "--------------------------------------------"

BUG_TEMPLATE="$TEMPLATES_DIR/bug.yml"

# Test 6: Bug template has developer agent
if grep -q "role: developer" "$BUG_TEMPLATE" 2>/dev/null; then
    pass "Scenario 2: Bug template includes developer agent"
else
    fail "Scenario 2: Bug template missing developer agent"
fi

# Test 7: Bug template is minimal (no code-reviewer, no security-reviewer)
BUG_AGENT_COUNT=$(grep -c "^  - name:" "$BUG_TEMPLATE" 2>/dev/null || echo 0)
if [[ "$BUG_AGENT_COUNT" -le 2 ]]; then
    pass "Scenario 2: Bug template has minimal team ($BUG_AGENT_COUNT agent(s))"
else
    fail "Scenario 2: Bug template has too many agents ($BUG_AGENT_COUNT) for a bug fix"
fi

# Test 8: Bug template use_cases match bug fix requests
if grep -q "Fixing a reported bug\|Resolving an error\|Debugging unexpected" "$BUG_TEMPLATE" 2>/dev/null; then
    pass "Scenario 2: Bug template use_cases match bug fix requests"
else
    fail "Scenario 2: Bug template use_cases don't match bug fix requests"
fi

echo ""

# ============================================================
# SCENARIO 3: PM Briefing Template Selection Flow
# ============================================================
echo "Scenario 3: PM briefing instructs template-based team selection"
echo "--------------------------------------------------------------"

# Test 9: PM briefing instructs to read templates from team-suggestions/
if grep -q "team-suggestions/" "$ORCH_FILE" 2>/dev/null; then
    pass "Scenario 3: PM briefing references team-suggestions/ directory"
else
    fail "Scenario 3: PM briefing doesn't reference team-suggestions/ directory"
fi

# Test 10: PM briefing uses AskUserQuestion for template selection
if grep -q "Which team template would you like to use" "$ORCH_FILE" 2>/dev/null; then
    pass "Scenario 3: PM briefing uses AskUserQuestion for template selection"
else
    fail "Scenario 3: PM briefing missing AskUserQuestion for template selection"
fi

# Test 11: PM briefing handles Custom option (no template)
if grep -q "After user selects 'Custom'" "$ORCH_FILE" 2>/dev/null; then
    pass "Scenario 3: PM briefing handles Custom (no template) option"
else
    fail "Scenario 3: PM briefing missing Custom option handling"
fi

echo ""

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
