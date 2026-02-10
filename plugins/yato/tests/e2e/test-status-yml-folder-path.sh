#!/bin/bash
# test-status-yml-folder-path.sh
#
# E2E Test: status.yml folder field contains absolute path
#
# Verifies that:
# 1. init-workflow.sh creates status.yml with absolute folder path
# 2. The folder path starts with /
# 3. The folder path contains the full path to the workflow directory
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All workflow creation goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="status-yml-folder-path"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-folder-path-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: status.yml Folder Path"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
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

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "function test() { return true; }" > "$TEST_DIR/app.js"

# Initialize git so init-workflow.sh works
cd "$TEST_DIR" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start
echo "  - Waiting for Claude to start..."
sleep 8

# Handle trust prompt
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
# Test 1: Create workflow through Claude and check folder path
# ============================================================
echo "Test 1: Creating workflow and checking folder path..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'test-folder-path'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

# Debug output
echo "  Debug - After workflow init:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -30 | tail -15
echo ""

# Find the workflow directory
WORKFLOW_DIR=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1)
STATUS_FILE="$WORKFLOW_DIR/status.yml"

if [[ -f "$STATUS_FILE" ]]; then
    pass "status.yml created"
else
    fail "status.yml not created"
fi

# ============================================================
# Test 2: Check folder field starts with /
# ============================================================
echo ""
echo "Test 2: Checking folder field is absolute path..."

# Extract folder value, handling the case where it might be quoted or have spaces
FOLDER_VALUE=$(grep "^folder:" "$STATUS_FILE" 2>/dev/null | sed 's/^folder: *//' | tr -d '"')

if [[ "$FOLDER_VALUE" == /* ]]; then
    pass "Folder field starts with / (absolute path)"
else
    fail "Folder field is not absolute path: $FOLDER_VALUE"
fi

# ============================================================
# Test 3: Check folder path contains .workflow
# ============================================================
echo ""
echo "Test 3: Checking folder path contains .workflow..."

if echo "$FOLDER_VALUE" | grep -q ".workflow"; then
    pass "Folder path contains .workflow"
else
    fail "Folder path missing .workflow: $FOLDER_VALUE"
fi

# ============================================================
# Test 4: Check folder path matches actual directory
# ============================================================
echo ""
echo "Test 4: Checking folder path matches actual directory..."

if [[ -d "$FOLDER_VALUE" ]]; then
    pass "Folder path is a valid directory"
else
    fail "Folder path is not a valid directory: $FOLDER_VALUE"
fi

# ============================================================
# Test 5: Verify full path format
# ============================================================
echo ""
echo "Test 5: Verifying full path format..."

if echo "$FOLDER_VALUE" | grep -qE "$TEST_DIR/.workflow/[0-9]{3}-"; then
    pass "Folder path has correct format: $FOLDER_VALUE"
else
    fail "Folder path format incorrect: $FOLDER_VALUE"
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
