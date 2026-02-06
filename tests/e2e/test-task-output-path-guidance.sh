#!/bin/bash
# test-task-output-path-guidance.sh
#
# E2E Test: Task Skill Contains OUTPUT_PATH Guidance
#
# BUG 2 REGRESSION TEST
#
# This test verifies:
# 1. parse-prd-to-tasks skill file contains OUTPUT_PATH guidance
# 2. Task description field mentions explicit file paths

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="task-output-path-guidance"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-$TEST_NAME-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Task OUTPUT_PATH Guidance (BUG 2)                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Track test results
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

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup test environment
mkdir -p "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

SKILL_FILE="$PROJECT_ROOT/skills/parse-prd-to-tasks/SKILL.md"

echo "Testing: $SKILL_FILE"
echo ""

# ============================================================
# Test skill file exists
# ============================================================
echo "Phase 1: Checking skill file exists..."

if [[ -f "$SKILL_FILE" ]]; then
    pass "parse-prd-to-tasks SKILL.md exists"
else
    fail "SKILL.md not found at $SKILL_FILE"
    exit 1
fi

echo ""

# ============================================================
# Test OUTPUT_PATH guidance in description field
# ============================================================
echo "Phase 2: Checking OUTPUT_PATH guidance..."

# Test 1: Task Fields section mentions OUTPUT_PATH
if grep -q "OUTPUT_PATH" "$SKILL_FILE" 2>/dev/null; then
    pass "SKILL.md contains OUTPUT_PATH guidance"
else
    fail "SKILL.md missing OUTPUT_PATH guidance"
fi

# Test 2: Description field mentions explicit paths
if grep -q "description.*OUTPUT_PATH" "$SKILL_FILE" 2>/dev/null; then
    pass "Task description field mentions OUTPUT_PATH requirement"
else
    fail "Task description field doesn't mention OUTPUT_PATH"
fi

# Test 3: Guidelines mention file paths
if grep -q "Be specific with file paths" "$SKILL_FILE" 2>/dev/null; then
    pass "Guidelines mention being specific with file paths"
else
    fail "Guidelines missing file path specificity rule"
fi

# Test 4: Guidelines have OUTPUT_PATH example
if grep -q "OUTPUT_PATH:" "$SKILL_FILE" 2>/dev/null; then
    pass "Guidelines include OUTPUT_PATH: example"
else
    fail "Guidelines missing OUTPUT_PATH: example"
fi

echo ""

# ============================================================
# RESULTS
# ============================================================
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                ║"
    EXIT_CODE=0
else
    printf "║  ❌ SOME TESTS FAILED (%d failed, %d passed)                      ║\n" $TESTS_FAILED $TESTS_PASSED
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
