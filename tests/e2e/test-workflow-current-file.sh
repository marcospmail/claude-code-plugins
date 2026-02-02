#!/bin/bash
# test-workflow-current-file.sh
#
# E2E Test: .workflow/current File Creation
#
# This test verifies:
# 1. init-workflow.sh creates .workflow/current file
# 2. The file contains the workflow folder name
# 3. get_current_workflow can read it from outside tmux

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="workflow-current-file"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-current-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: .workflow/current File Creation                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
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
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup and create workflow
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

# Create session (but we'll also test from outside tmux)
tmux new-session -d -s "$SESSION_NAME" -n "pm" -c "$TEST_DIR"

# Initialize workflow
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test current file" > /dev/null 2>&1

echo "  - Workflow initialized"
echo ""

# ============================================================
# PHASE 2: Verify .workflow/current file exists
# ============================================================
echo "Phase 2: Checking .workflow/current file..."

CURRENT_FILE="$TEST_DIR/.workflow/current"

# Test 1: .workflow/current file exists
if [[ -f "$CURRENT_FILE" ]]; then
    pass ".workflow/current file exists"
else
    fail ".workflow/current file not found"
    exit 1
fi

# Test 2: File contains workflow folder name
CURRENT_CONTENT=$(cat "$CURRENT_FILE")
if [[ "$CURRENT_CONTENT" =~ ^[0-9]{3}- ]]; then
    pass ".workflow/current contains valid workflow name: $CURRENT_CONTENT"
else
    fail ".workflow/current has invalid content: $CURRENT_CONTENT"
fi

# Test 3: Referenced folder exists
if [[ -d "$TEST_DIR/.workflow/$CURRENT_CONTENT" ]]; then
    pass "Referenced workflow folder exists"
else
    fail "Referenced workflow folder doesn't exist"
fi

echo ""

# ============================================================
# PHASE 3: Verify get_current_workflow works outside tmux
# ============================================================
echo "Phase 3: Testing get_current_workflow from outside tmux..."

# Source workflow-utils.sh outside of tmux context
# (unset TMUX to simulate being outside tmux)
ORIGINAL_TMUX="$TMUX"
unset TMUX

source "$PROJECT_ROOT/bin/workflow-utils.sh"

RESULT=$(get_current_workflow "$TEST_DIR")

# Restore TMUX
if [[ -n "$ORIGINAL_TMUX" ]]; then
    export TMUX="$ORIGINAL_TMUX"
fi

# Test 4: get_current_workflow returns correct value outside tmux
if [[ "$RESULT" == "$CURRENT_CONTENT" ]]; then
    pass "get_current_workflow works outside tmux"
else
    fail "get_current_workflow failed outside tmux: got '$RESULT', expected '$CURRENT_CONTENT'"
fi

# Test 5: get_current_workflow_path also works
unset TMUX
RESULT_PATH=$(get_current_workflow_path "$TEST_DIR")
if [[ -n "$ORIGINAL_TMUX" ]]; then
    export TMUX="$ORIGINAL_TMUX"
fi

if [[ "$RESULT_PATH" == "$TEST_DIR/.workflow/$CURRENT_CONTENT" ]]; then
    pass "get_current_workflow_path works outside tmux"
else
    fail "get_current_workflow_path failed: got '$RESULT_PATH'"
fi

echo ""

# ============================================================
# PHASE 4: Verify init-workflow.sh creates file
# ============================================================
echo "Phase 4: Checking init-workflow.sh template..."

INIT_WORKFLOW="$PROJECT_ROOT/bin/init-workflow.sh"

# Test 6: init-workflow.sh contains code to create current file
if grep -q '.workflow/current' "$INIT_WORKFLOW" 2>/dev/null; then
    pass "init-workflow.sh contains .workflow/current file creation"
else
    fail "init-workflow.sh doesn't create .workflow/current file"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
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
