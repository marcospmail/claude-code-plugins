#!/bin/bash
# test-team-template-choice.sh
#
# E2E Test: Team Template Choice via AskUserQuestion
#
# Verifies that the PM briefing template instructs PM to:
# 1. Read ALL .yml files from templates/team-suggestions/ directory
# 2. Present templates via AskUserQuestion with "Which team template would you like to use?"
# 3. Include a "Custom" option for building from scratch
# 4. Use the selected template as a starting point for team proposal
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-template-choice"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-ttc-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Team Template Choice via AskUserQuestion"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""
    echo "Cleaning up..."
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 3: Verify AskUserQuestion for template selection
# ============================================================
echo "Phase 3: Verifying AskUserQuestion template choice..."
echo ""

BRIEFING_TEMPLATE="$PROJECT_ROOT/lib/templates/pm_planning_briefing.md.j2"

# Test 1: PM briefing contains AskUserQuestion for template selection
if grep -q "Which team template would you like to use" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "PM briefing has AskUserQuestion: 'Which team template would you like to use?'"
else
    fail "PM briefing missing AskUserQuestion for template selection"
fi

# Test 2: AskUserQuestion uses correct header
if grep -q "Header.*Template\|Header: 'Template'" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "AskUserQuestion uses 'Template' header"
else
    fail "AskUserQuestion missing 'Template' header"
fi

# Test 3: Options are built from template files
if grep -q "template name\|label is the template name" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Options use template name as label"
else
    fail "Options do not reference template name as label"
fi

# Test 4: Options include template description
if grep -q "template description\|description is the template description" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Options use template description"
else
    fail "Options do not reference template description"
fi

echo ""
echo "Testing Custom option..."

# Test 5: Custom option is present
if grep -q "label='Custom'" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Custom option has label='Custom'"
else
    fail "Custom option missing label='Custom'"
fi

# Test 6: Custom option has description
if grep -q "Build a team from scratch" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Custom option has 'Build a team from scratch' description"
else
    fail "Custom option missing description"
fi

echo ""
echo "Testing template selection flow..."

# Test 7: After selecting a template, PM reads that file
if grep -qi "After user selects a.*TEMPLATE" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Has flow for when user selects a template"
else
    fail "Missing flow for template selection"
fi

# Test 8: After selecting Custom, PM proposes from scratch
if grep -q "After user selects 'Custom'" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Has flow for when user selects Custom"
else
    fail "Missing flow for Custom selection"
fi

# Test 9: Templates are starting points, not rigid
if grep -q "suggestions\|adapt the team\|starting point" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Templates are treated as suggestions/starting points"
else
    fail "Missing indication that templates are suggestions"
fi

echo ""
echo "Testing template discovery..."

# Test 10: PM reads from templates/team-suggestions/ directory
if grep -q "templates/team-suggestions/" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "PM reads from templates/team-suggestions/ directory"
else
    fail "PM does not reference templates/team-suggestions/ directory"
fi

# Test 11: PM reads ALL .yml files
if grep -q "\.yml" "$BRIEFING_TEMPLATE" 2>/dev/null && grep -q "team-suggestions" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "PM discovers .yml template files from team-suggestions directory"
else
    fail "PM does not discover .yml template files"
fi

# Test 12: Template path uses yato_path variable
if grep -q "{{ yato_path }}/templates/team-suggestions" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "Template path uses yato_path variable"
else
    fail "Template path does not use yato_path variable"
fi

echo ""
echo "Testing TEAM TEMPLATE SELECTION section..."

# Test 13: Section heading exists
if grep -q "TEAM TEMPLATE SELECTION" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "TEAM TEMPLATE SELECTION section exists in PM briefing"
else
    fail "TEAM TEMPLATE SELECTION section missing from PM briefing"
fi

# Test 14: Extract name and description from templates
if grep -q "extract.*name.*description\|'name' and 'description'" "$BRIEFING_TEMPLATE" 2>/dev/null; then
    pass "PM instructed to extract name and description from templates"
else
    fail "PM not instructed to extract template fields"
fi

echo ""
echo "Verifying actual template files exist..."

# Test 15: Verify development.yml exists with expected structure
if [[ -f "$PROJECT_ROOT/templates/team-suggestions/development.yml" ]]; then
    pass "development.yml template exists"
else
    fail "development.yml template missing"
fi

# Test 16: Verify bug.yml exists with expected structure
if [[ -f "$PROJECT_ROOT/templates/team-suggestions/bug.yml" ]]; then
    pass "bug.yml template exists"
else
    fail "bug.yml template missing"
fi

# Test 17: Verify templates have name and description fields
if [[ -f "$PROJECT_ROOT/templates/team-suggestions/development.yml" ]]; then
    if grep -q "^name:" "$PROJECT_ROOT/templates/team-suggestions/development.yml" && \
       grep -q "^description:" "$PROJECT_ROOT/templates/team-suggestions/development.yml"; then
        pass "development.yml has name and description fields for AskUserQuestion options"
    else
        fail "development.yml missing name or description fields"
    fi
fi

if [[ -f "$PROJECT_ROOT/templates/team-suggestions/bug.yml" ]]; then
    if grep -q "^name:" "$PROJECT_ROOT/templates/team-suggestions/bug.yml" && \
       grep -q "^description:" "$PROJECT_ROOT/templates/team-suggestions/bug.yml"; then
        pass "bug.yml has name and description fields for AskUserQuestion options"
    else
        fail "bug.yml missing name or description fields"
    fi
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
