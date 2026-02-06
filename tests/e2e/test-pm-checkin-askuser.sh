#!/bin/bash
# test-pm-checkin-askuser.sh
#
# E2E Test: Verify PM uses AskUserQuestion tool for check-in frequency
#
# Verifies that orchestrator.py PM briefing includes AskUserQuestion
# instructions with the correct check-in interval options.

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
export TMUX_SOCKET="yato-e2e-test"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: PM Check-in AskUserQuestion                       ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

TARGET_FILE="$PROJECT_ROOT/lib/orchestrator.py"
PASSED=0
FAILED=0

assert_grep() {
    local description="$1"
    local pattern="$2"

    if grep -q "$pattern" "$TARGET_FILE"; then
        echo "  ✅ $description"
        PASSED=$((PASSED + 1))
    else
        echo "  ❌ $description"
        echo "     Pattern not found: $pattern"
        FAILED=$((FAILED + 1))
    fi
}

# Verify AskUserQuestion is used for check-in interval
assert_grep "PM briefing mentions AskUserQuestion for check-in interval" "check-in interval.*AskUserQuestion"

# Verify 3 minutes option exists
assert_grep "3 minutes option exists" "'3 minutes'"

# Verify 5 minutes option with Recommended tag
assert_grep "5 minutes (Recommended) option exists" "5 minutes (Recommended)"

# Verify 10 minutes option exists
assert_grep "10 minutes option exists" "'10 minutes'"

# Verify update_checkin_interval command is referenced
assert_grep "update_checkin_interval command referenced" "update_checkin_interval"

echo ""
TOTAL=$((PASSED + FAILED))
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($PASSED/$TOTAL)                                ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 0
else
    echo "║  ❌ SOME TESTS FAILED ($FAILED/$TOTAL failed)                        ║"
    echo "╚══════════════════════════════════════════════════════════════╝"
    exit 1
fi
