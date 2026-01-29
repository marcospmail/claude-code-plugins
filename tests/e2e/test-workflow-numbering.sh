#!/bin/bash
# test-workflow-numbering.sh
#
# E2E Test: Workflow Sequential Numbering
#
# Verifies workflows get sequential numbers: 001, 002, 003

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="workflow-numbering"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Workflow Sequential Numbering                     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup
mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

echo "Creating 3 workflows sequentially..."
echo ""

# Create first workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "First workflow" > /dev/null 2>&1
WF1=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^001-" | head -1)
if [[ "$WF1" == 001-* ]]; then
    pass "First workflow starts with 001-"
else
    fail "First workflow should start with 001-, got: $WF1"
fi

# Create second workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Second workflow" > /dev/null 2>&1
WF2=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^002-" | head -1)
if [[ "$WF2" == 002-* ]]; then
    pass "Second workflow starts with 002-"
else
    fail "Second workflow should start with 002-, got: $WF2"
fi

# Create third workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Third workflow" > /dev/null 2>&1
WF3=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^003-" | head -1)
if [[ "$WF3" == 003-* ]]; then
    pass "Third workflow starts with 003-"
else
    fail "Third workflow should start with 003-, got: $WF3"
fi

# Verify all workflows exist
WORKFLOW_COUNT=$(ls -d "$TEST_DIR/.workflow"/0* 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WORKFLOW_COUNT" -eq 3 ]]; then
    pass "3 workflow folders created"
else
    fail "Expected 3 workflow folders, got: $WORKFLOW_COUNT"
fi

# Verify latest workflow is 003 (they should be numbered sequentially)
LATEST=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | sort | tail -1)
if [[ "$LATEST" == "$WF3" ]]; then
    pass "Latest workflow is 003-* (sequential numbering works)"
else
    fail "Latest should be $WF3, got: $LATEST"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                  ║"
    exit 0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                        ║"
    exit 1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
