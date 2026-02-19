#!/bin/bash
# test-defaults-conf-suffixes.sh
#
# E2E Test: defaults.conf Suffixes Contain File-Reading Reminders
#
# Verifies that the message suffixes in defaults.conf include reminders
# for agents and PM to re-read their key files:
# 1. PM_TO_AGENTS_SUFFIX references identity.yml, instructions.md, constraints.md, agent-tasks.md
# 2. AGENTS_TO_PM_SUFFIX references identity.yml, instructions.md, constraints.md
# 3. CHECKIN_TO_PM_SUFFIX references identity.yml, instructions.md, constraints.md

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="defaults-conf-suffixes"

echo "======================================================================"
echo "  E2E Test: defaults.conf Suffixes Contain File-Reading Reminders"
echo "======================================================================"
echo ""

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

DEFAULTS_CONF="$PROJECT_ROOT/config/defaults.conf"

# ============================================================
# PHASE 1: Verify defaults.conf exists
# ============================================================
echo "Phase 1: Checking defaults.conf exists..."

if [[ -f "$DEFAULTS_CONF" ]]; then
    pass "defaults.conf exists at $DEFAULTS_CONF"
else
    fail "defaults.conf not found at $DEFAULTS_CONF"
    exit 1
fi

echo ""

# ============================================================
# PHASE 2: Extract and verify PM_TO_AGENTS_SUFFIX
# ============================================================
echo "Phase 2: Verifying PM_TO_AGENTS_SUFFIX..."

# Extract the PM_TO_AGENTS_SUFFIX block (from the variable to the next blank line or next variable)
PM_TO_AGENTS=$(sed -n '/^PM_TO_AGENTS_SUFFIX=/,/^$/p' "$DEFAULTS_CONF")

if [[ -n "$PM_TO_AGENTS" ]]; then
    pass "PM_TO_AGENTS_SUFFIX is defined"
else
    fail "PM_TO_AGENTS_SUFFIX not found in defaults.conf"
fi

if echo "$PM_TO_AGENTS" | grep -q "identity.yml"; then
    pass "PM_TO_AGENTS_SUFFIX references identity.yml"
else
    fail "PM_TO_AGENTS_SUFFIX missing identity.yml reference"
fi

if echo "$PM_TO_AGENTS" | grep -q "instructions.md"; then
    pass "PM_TO_AGENTS_SUFFIX references instructions.md"
else
    fail "PM_TO_AGENTS_SUFFIX missing instructions.md reference"
fi

if echo "$PM_TO_AGENTS" | grep -q "constraints.md"; then
    pass "PM_TO_AGENTS_SUFFIX references constraints.md"
else
    fail "PM_TO_AGENTS_SUFFIX missing constraints.md reference"
fi

if echo "$PM_TO_AGENTS" | grep -q "agent-tasks.md"; then
    pass "PM_TO_AGENTS_SUFFIX references agent-tasks.md"
else
    fail "PM_TO_AGENTS_SUFFIX missing agent-tasks.md reference"
fi

echo ""

# ============================================================
# PHASE 3: Extract and verify AGENTS_TO_PM_SUFFIX
# ============================================================
echo "Phase 3: Verifying AGENTS_TO_PM_SUFFIX..."

AGENTS_TO_PM=$(sed -n '/^AGENTS_TO_PM_SUFFIX=/,/^$/p' "$DEFAULTS_CONF")

if [[ -n "$AGENTS_TO_PM" ]]; then
    pass "AGENTS_TO_PM_SUFFIX is defined"
else
    fail "AGENTS_TO_PM_SUFFIX not found in defaults.conf"
fi

if echo "$AGENTS_TO_PM" | grep -q "identity.yml"; then
    pass "AGENTS_TO_PM_SUFFIX references identity.yml"
else
    fail "AGENTS_TO_PM_SUFFIX missing identity.yml reference"
fi

if echo "$AGENTS_TO_PM" | grep -q "instructions.md"; then
    pass "AGENTS_TO_PM_SUFFIX references instructions.md"
else
    fail "AGENTS_TO_PM_SUFFIX missing instructions.md reference"
fi

if echo "$AGENTS_TO_PM" | grep -q "constraints.md"; then
    pass "AGENTS_TO_PM_SUFFIX references constraints.md"
else
    fail "AGENTS_TO_PM_SUFFIX missing constraints.md reference"
fi

echo ""

# ============================================================
# PHASE 4: Extract and verify CHECKIN_TO_PM_SUFFIX
# ============================================================
echo "Phase 4: Verifying CHECKIN_TO_PM_SUFFIX..."

CHECKIN_TO_PM=$(sed -n '/^CHECKIN_TO_PM_SUFFIX=/,/^$/p' "$DEFAULTS_CONF")

if [[ -n "$CHECKIN_TO_PM" ]]; then
    pass "CHECKIN_TO_PM_SUFFIX is defined"
else
    fail "CHECKIN_TO_PM_SUFFIX not found in defaults.conf"
fi

if echo "$CHECKIN_TO_PM" | grep -q "identity.yml"; then
    pass "CHECKIN_TO_PM_SUFFIX references identity.yml"
else
    fail "CHECKIN_TO_PM_SUFFIX missing identity.yml reference"
fi

if echo "$CHECKIN_TO_PM" | grep -q "instructions.md"; then
    pass "CHECKIN_TO_PM_SUFFIX references instructions.md"
else
    fail "CHECKIN_TO_PM_SUFFIX missing instructions.md reference"
fi

if echo "$CHECKIN_TO_PM" | grep -q "constraints.md"; then
    pass "CHECKIN_TO_PM_SUFFIX references constraints.md"
else
    fail "CHECKIN_TO_PM_SUFFIX missing constraints.md reference"
fi

echo ""

# ============================================================
# PHASE 5: Verify reminders use [REMINDER] format
# ============================================================
echo "Phase 5: Verifying [REMINDER] format..."

if echo "$PM_TO_AGENTS" | grep -q "\[REMINDER\].*identity.yml"; then
    pass "PM_TO_AGENTS_SUFFIX uses [REMINDER] format for identity.yml"
else
    fail "PM_TO_AGENTS_SUFFIX not using [REMINDER] format for identity.yml"
fi

if echo "$AGENTS_TO_PM" | grep -q "\[REMINDER\].*identity.yml"; then
    pass "AGENTS_TO_PM_SUFFIX uses [REMINDER] format for identity.yml"
else
    fail "AGENTS_TO_PM_SUFFIX not using [REMINDER] format for identity.yml"
fi

if echo "$CHECKIN_TO_PM" | grep -q "\[REMINDER\].*identity.yml"; then
    pass "CHECKIN_TO_PM_SUFFIX uses [REMINDER] format for identity.yml"
else
    fail "CHECKIN_TO_PM_SUFFIX not using [REMINDER] format for identity.yml"
fi

echo ""

# ============================================================
# RESULTS
# ============================================================
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    EXIT_CODE=0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    EXIT_CODE=1
fi
echo "======================================================================"
echo ""

exit $EXIT_CODE
