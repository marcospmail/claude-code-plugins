#!/bin/bash
# E2E Test: constraints.md creation
#
# Verifies that:
# 1. PM gets constraints.md (not constraints.example.md)
# 2. PM constraints.md contains "cannot modify any code"
# 3. Other agents get constraints.md file
# 4. No constraints.example.md files are created

# Note: Don't use set -e as test failures should be counted, not exit immediately

# Test setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-constraints-$TEST_ID"
SESSION_NAME="e2e-constraints-$TEST_ID"

# Test counters
TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "  PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "  FAIL: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

cleanup() {
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# ============================================================
# Setup
# ============================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: constraints.md Creation                           ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo ""

mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init -q
git config user.name "Test"
git config user.email "test@test.com"

# ============================================================
# Test 1: PM constraints.md exists after workflow init
# ============================================================

echo "Test 1: Creating workflow and checking PM constraints.md..."

$BIN_DIR/init-workflow.sh "$TEST_DIR" "test-constraints" > /dev/null

# Find the workflow directory
WORKFLOW_DIR=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1)
PM_CONSTRAINTS="$WORKFLOW_DIR/agents/pm/constraints.md"

if [[ -f "$PM_CONSTRAINTS" ]]; then
    pass "PM constraints.md exists"
else
    fail "PM constraints.md not found"
fi

# ============================================================
# Test 2: PM constraints.md contains code modification rule
# ============================================================

echo ""
echo "Test 2: Checking PM constraints.md content..."

if grep -qi "cannot modify.*code\|cannot write.*code\|do not.*modify.*code" "$PM_CONSTRAINTS" 2>/dev/null; then
    pass "PM constraints.md contains code modification restriction"
else
    fail "PM constraints.md missing code modification restriction"
fi

# ============================================================
# Test 3: No constraints.example.md for PM
# ============================================================

echo ""
echo "Test 3: Checking no constraints.example.md for PM..."

PM_EXAMPLE="$WORKFLOW_DIR/agents/pm/constraints.example.md"
if [[ ! -f "$PM_EXAMPLE" ]]; then
    pass "No constraints.example.md for PM (correct)"
else
    fail "constraints.example.md exists for PM (should not exist)"
fi

# ============================================================
# Test 4: Create agent and check constraints.md exists
# ============================================================

echo ""
echo "Test 4: Creating agent and checking constraints.md..."

# Create a tmux session for the agent
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "$(basename "$WORKFLOW_DIR")"

# Create a developer agent
WORKFLOW_NAME="$(basename "$WORKFLOW_DIR")"
$BIN_DIR/create-agent.sh "$SESSION_NAME" developer -p "$TEST_DIR" --pm-window "$SESSION_NAME:0" --no-start 2>&1 | head -20 || true

# Wait a moment
sleep 2

# Check for constraints.md in developer directory
DEV_CONSTRAINTS="$WORKFLOW_DIR/agents/developer/constraints.md"
if [[ -f "$DEV_CONSTRAINTS" ]]; then
    pass "Developer constraints.md exists"
else
    fail "Developer constraints.md not found"
fi

# ============================================================
# Test 5: No constraints.example.md for developer
# ============================================================

echo ""
echo "Test 5: Checking no constraints.example.md for developer..."

DEV_EXAMPLE="$WORKFLOW_DIR/agents/developer/constraints.example.md"
if [[ ! -f "$DEV_EXAMPLE" ]]; then
    pass "No constraints.example.md for developer (correct)"
else
    fail "constraints.example.md exists for developer (should not exist)"
fi

# ============================================================
# Test 6: Developer constraints.md is customizable (has placeholder comments)
# ============================================================

echo ""
echo "Test 6: Checking developer constraints.md is customizable..."

if grep -q "# Add project-specific constraints\|# Examples:" "$DEV_CONSTRAINTS" 2>/dev/null; then
    pass "Developer constraints.md has customization hints"
else
    fail "Developer constraints.md missing customization hints"
fi

# ============================================================
# Results
# ============================================================

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)                                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)              ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 1
fi
