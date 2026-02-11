#!/bin/bash
# test-task-output-path-guidance.sh
#
# E2E Test: Task Skill Contains OUTPUT_PATH Guidance
#
# BUG 2 REGRESSION TEST
#
# Verifies through Claude Code:
# 1. parse-prd-to-tasks skill file contains OUTPUT_PATH guidance
# 2. Task description field mentions explicit file paths
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All execution goes through Claude running inside a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="task-output-path-guidance"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Task OUTPUT_PATH Guidance (BUG 2)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"

SKILL_FILE="$PROJECT_ROOT/skills/parse-prd-to-tasks/SKILL.md"

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "  - Waiting for Claude to start..."
sleep 8

# Check for trust prompt and send Enter to accept
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
# PHASE 2: Verify skill file exists via Claude
# ============================================================
echo "Phase 2: Checking skill file exists..."

# Ask Claude to verify the skill file exists
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: test -f $SKILL_FILE && echo 'SKILL_FILE_EXISTS' || echo 'SKILL_FILE_MISSING'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt if it appears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    echo "  - Skill trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

# Verify directly from test runner
if [[ -f "$SKILL_FILE" ]]; then
    pass "parse-prd-to-tasks SKILL.md exists"
else
    fail "SKILL.md not found at $SKILL_FILE"
    exit 1
fi

echo ""

# ============================================================
# PHASE 3: Check OUTPUT_PATH guidance via Claude
# ============================================================
echo "Phase 3: Checking OUTPUT_PATH guidance..."

# Ask Claude to grep for OUTPUT_PATH patterns
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: grep -c 'OUTPUT_PATH' $SKILL_FILE && grep -c 'Be specific with file paths' $SKILL_FILE"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle skill trust prompt
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

# Verify directly from test runner
if grep -q "OUTPUT_PATH" "$SKILL_FILE" 2>/dev/null; then
    pass "SKILL.md contains OUTPUT_PATH guidance"
else
    fail "SKILL.md missing OUTPUT_PATH guidance"
fi

if grep -q "description.*OUTPUT_PATH" "$SKILL_FILE" 2>/dev/null; then
    pass "Task description field mentions OUTPUT_PATH requirement"
else
    fail "Task description field doesn't mention OUTPUT_PATH"
fi

if grep -q "Be specific with file paths" "$SKILL_FILE" 2>/dev/null; then
    pass "Guidelines mention being specific with file paths"
else
    fail "Guidelines missing file path specificity rule"
fi

if grep -q "OUTPUT_PATH:" "$SKILL_FILE" 2>/dev/null; then
    pass "Guidelines include OUTPUT_PATH: example"
else
    fail "Guidelines missing OUTPUT_PATH: example"
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
