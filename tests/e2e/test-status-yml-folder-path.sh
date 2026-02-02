#!/bin/bash
# E2E Test: status.yml folder field contains absolute path
#
# Verifies that:
# 1. init-workflow.sh creates status.yml with absolute folder path
# 2. The folder path starts with /
# 3. The folder path contains the full path to the workflow directory

# Note: Don't use set -e as test failures should be counted, not exit immediately

# Test setup
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BIN_DIR="$SCRIPT_DIR/../../bin"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-folder-path-$TEST_ID"

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
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

# ============================================================
# Setup
# ============================================================

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: status.yml Folder Path                            ║"
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
# Test 1: Create workflow and check folder path
# ============================================================

echo "Test 1: Creating workflow and checking folder path..."

$BIN_DIR/init-workflow.sh "$TEST_DIR" "test-folder-path" > /dev/null

# Find the workflow directory
WORKFLOW_DIR=$(ls -d "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-* 2>/dev/null | head -1)
STATUS_FILE="$WORKFLOW_DIR/status.yml"

if [[ ! -f "$STATUS_FILE" ]]; then
    fail "status.yml not created"
else
    pass "status.yml created"
fi

# ============================================================
# Test 2: Check folder field starts with /
# ============================================================

echo ""
echo "Test 2: Checking folder field is absolute path..."

# Extract folder value, handling the case where it might be quoted or have spaces
FOLDER_VALUE=$(grep "^folder:" "$STATUS_FILE" | sed 's/^folder: *//' | tr -d '"')

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

EXPECTED_PATTERN="$TEST_DIR/.workflow/[0-9][0-9][0-9]-"
if echo "$FOLDER_VALUE" | grep -qE "$TEST_DIR/.workflow/[0-9]{3}-"; then
    pass "Folder path has correct format: $FOLDER_VALUE"
else
    fail "Folder path format incorrect: $FOLDER_VALUE"
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
