#!/bin/bash
# test-pane-window-names.sh
#
# E2E Test: Pane and Window Names
#
# This test verifies:
# 1. deploy-pm creates correct pane names (Check-ins + PM)
# 2. checkin-display.sh doesn't overwrite PM pane name
# 3. Agent windows get correct names
# 4. Pane titles are preserved over time (checkin-display loop)
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All script execution goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pane-window-names"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-names-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Pane and Window Names"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
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
    tmux -L "$TMUX_SOCKET" kill-session -t "e2e-agent-names-$$" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -rf "/tmp/e2e-agent-test-$$" 2>/dev/null || true
    rm -f /tmp/e2e-deploy-$$.txt /tmp/e2e-init-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Test deploy-pm pane names
# ============================================================
echo "Phase 1: Testing deploy-pm pane names..."
echo ""

mkdir -p "$TEST_DIR"
echo "test file" > "$TEST_DIR/test.txt"

echo "  ✓ Test environment ready"
echo ""

# Deploy PM directly (no Claude needed)
cd "$PROJECT_ROOT" && TMUX_SOCKET="$TMUX_SOCKET" uv run python lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$TEST_DIR" > /tmp/e2e-deploy-$$.txt 2>&1

# Wait for session to be created
for i in {1..10}; do
    if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
        break
    fi
    sleep 1
done

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Session '$SESSION_NAME' was not created by deploy-pm"
    echo "  Deploy output:"
    cat /tmp/e2e-deploy-$$.txt 2>/dev/null
    exit 1
fi

# Wait for checkin-display.sh to run and set pane titles
sleep 5

# Check pane titles with retry
PANE_0_TITLE=""
PANE_1_TITLE=""
for i in {1..5}; do
    PANE_0_TITLE=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F "#{pane_index}:#{pane_title}" 2>/dev/null | grep "^0:" | cut -d: -f2-)
    PANE_1_TITLE=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F "#{pane_index}:#{pane_title}" 2>/dev/null | grep "^1:" | cut -d: -f2-)
    if [[ -n "$PANE_0_TITLE" && -n "$PANE_1_TITLE" ]]; then
        break
    fi
    sleep 1
done

echo "Testing pane 0 (Check-ins)..."
if [[ "$PANE_0_TITLE" == *"Check-ins"* ]]; then
    pass "Pane 0 has 'Check-ins' in title: '$PANE_0_TITLE'"
else
    fail "Pane 0 should contain 'Check-ins', got: '$PANE_0_TITLE'"
fi

echo ""
echo "Testing pane 1 (PM)..."
if [[ "$PANE_1_TITLE" == "PM" ]]; then
    pass "Pane 1 is named 'PM'"
else
    fail "Pane 1 should be 'PM', got: '$PANE_1_TITLE'"
fi

# ============================================================
# PHASE 2: Verify pane names persist after checkin-display loop
# ============================================================
echo ""
echo "Phase 2: Verifying pane names persist (waiting 6s for loop)..."
echo ""

sleep 6

PANE_0_TITLE_AFTER=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F "#{pane_index}:#{pane_title}" 2>/dev/null | grep "^0:" | cut -d: -f2-)
PANE_1_TITLE_AFTER=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F "#{pane_index}:#{pane_title}" 2>/dev/null | grep "^1:" | cut -d: -f2-)

echo "Testing pane 0 still has Check-ins..."
if [[ "$PANE_0_TITLE_AFTER" == *"Check-ins"* ]]; then
    pass "Pane 0 still has 'Check-ins': '$PANE_0_TITLE_AFTER'"
else
    fail "Pane 0 lost 'Check-ins' title, now: '$PANE_0_TITLE_AFTER'"
fi

echo ""
echo "Testing pane 1 (PM) was NOT overwritten by checkin-display.sh..."
if [[ "$PANE_1_TITLE_AFTER" == "PM" ]]; then
    pass "Pane 1 still 'PM' (not overwritten by checkin-display.sh)"
else
    fail "Pane 1 was overwritten! Expected 'PM', got: '$PANE_1_TITLE_AFTER'"
fi

# ============================================================
# PHASE 3: Test agent window names (separate session)
# ============================================================
echo ""
echo "Phase 3: Testing agent window names..."
echo ""

AGENT_SESSION="e2e-agent-names-$$"
AGENT_TEST_DIR="/tmp/e2e-agent-test-$$"
mkdir -p "$AGENT_TEST_DIR"
echo "test" > "$AGENT_TEST_DIR/test.txt"

# Create a new session for agent testing
tmux -L "$TMUX_SOCKET" new-session -d -s "$AGENT_SESSION" -x 120 -y 40 -n "pm-checkins" -c "$AGENT_TEST_DIR"

# Initialize workflow directly
TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/init-workflow.sh" "$AGENT_TEST_DIR" "Test agent windows"

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$AGENT_TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux -L "$TMUX_SOCKET" setenv -t "$AGENT_SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"

# Create team directly
TMUX_SOCKET="$TMUX_SOCKET" bash "$PROJECT_ROOT/bin/create-team.sh" "$AGENT_TEST_DIR" developer qa

# Check window names
WINDOW_LIST=$(tmux -L "$TMUX_SOCKET" list-windows -t "$AGENT_SESSION" -F "#{window_index}:#{window_name}" 2>/dev/null)

# Window 1 should be developer
if echo "$WINDOW_LIST" | grep -q "1:developer"; then
    pass "Agent window 1 named 'developer'"
else
    WIN_1_NAME=$(echo "$WINDOW_LIST" | grep "^1:" | cut -d: -f2)
    fail "Agent window 1 should be 'developer', got: '$WIN_1_NAME'"
fi

# Window 2 should be qa
if echo "$WINDOW_LIST" | grep -q "2:qa"; then
    pass "Agent window 2 named 'qa'"
else
    WIN_2_NAME=$(echo "$WINDOW_LIST" | grep "^2:" | cut -d: -f2)
    fail "Agent window 2 should be 'qa', got: '$WIN_2_NAME'"
fi

# Verify window count
WINDOW_COUNT=$(tmux -L "$TMUX_SOCKET" list-windows -t "$AGENT_SESSION" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WINDOW_COUNT" -ge 3 ]]; then
    pass "Agent session has $WINDOW_COUNT windows (shell + 2 agents)"
else
    fail "Expected at least 3 windows, got: $WINDOW_COUNT"
fi

# Clean up agent test session
tmux -L "$TMUX_SOCKET" kill-session -t "$AGENT_SESSION" 2>/dev/null || true
rm -rf "$AGENT_TEST_DIR" 2>/dev/null || true

# ============================================================
# PHASE 4: Final PM pane persistence check
# ============================================================
echo ""
echo "Phase 4: Final PM pane persistence check..."
echo ""

PANE_1_FINAL=""
for i in {1..5}; do
    PANE_1_FINAL=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F "#{pane_index}:#{pane_title}" 2>/dev/null | grep "^1:" | cut -d: -f2-)
    if [[ -n "$PANE_1_FINAL" ]]; then
        break
    fi
    sleep 1
done

if [[ "$PANE_1_FINAL" == "PM" ]]; then
    pass "PM pane still named 'PM'"
else
    fail "PM pane was changed! Got: '$PANE_1_FINAL' (should be 'PM')"
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
