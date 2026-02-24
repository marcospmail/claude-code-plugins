#!/bin/bash
# test-block-cancel-checkin-hook.sh
#
# E2E Test: Verify cancel-checkin is blocked for ALL agents via plugin hook
#
# Tests through tmux session/window role detection:
# 1. Hook is registered in hooks.json with Bash matcher
# 2. PM is blocked from canceling check-ins
# 3. Developer is blocked from canceling check-ins
# 4. QA is blocked from canceling check-ins
# 5. User (no matching identity) is allowed
# 6. Non-checkin commands are allowed for agents
#
# All tests use tmux-based role detection (identity.yml + session/window matching).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="block-cancel-checkin"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-cancel-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-hook-output-$TEST_NAME-$TEST_ID"
MAX_WAIT=30

echo "======================================================================"
echo "  E2E Test: Block Cancel Check-in Hook (Plugin-Level)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/block-checkin-cancel.sh"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

# Helper: run hook from a tmux pane and capture output
run_hook_in_pane() {
    local pane="$1"
    local command_json="$2"

    rm -f "$OUTPUT_FILE"

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:$pane" \
        "echo '$command_json' | HOOK_CWD='$TEST_DIR' WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' bash '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1; echo EXIT_CODE=\$? >> '$OUTPUT_FILE' && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

    local waited=0
    while [[ $waited -lt $MAX_WAIT ]]; do
        if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
            cat "$OUTPUT_FILE"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "TIMEOUT"
    return 1
}

get_exit_code() {
    grep "EXIT_CODE=" "$OUTPUT_FILE" 2>/dev/null | tail -1 | cut -d= -f2
}

# ============================================================
# Phase 1: Verify hook configuration
# ============================================================
echo "Phase 1: Checking hook configuration..."

if [[ -f "$HOOK_SCRIPT" ]]; then
    pass "Hook script exists"
else
    fail "Hook script not found at $HOOK_SCRIPT"
    exit 1
fi

if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("block-checkin-cancel.sh"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "PreToolUse hook configured with matcher 'Bash'"
else
    fail "PreToolUse hook not configured correctly in hooks.json"
    exit 1
fi

echo ""

# ============================================================
# Phase 2: Setup test environment
# ============================================================
echo "Phase 2: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/pm"
mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/developer"
mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/qa"

# Create tmux session first to capture pane IDs for identity.yml
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow
PM_PANE_ID=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F '#{pane_id}' | head -1)
DEV_PANE_ID=$(tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" -P -F '#{pane_id}' 2>/dev/null)
QA_PANE_ID=$(tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" -P -F '#{pane_id}' 2>/dev/null)
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
sleep 2

# Create identity.yml files with pane_id for role detection
cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_ID"
window: 0
workflow: 001-test-workflow
can_modify_code: false
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/developer/identity.yml" << EOF
name: developer
role: developer
model: sonnet
pane_id: "$DEV_PANE_ID"
window: 1
workflow: 001-test-workflow
can_modify_code: true
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/qa/identity.yml" << EOF
name: qa
role: qa
model: sonnet
pane_id: "$QA_PANE_ID"
window: 2
workflow: 001-test-workflow
can_modify_code: test-only
EOF

pass "Created test environment with pane_id-based identity.yml files and tmux windows"
echo ""

# Cancel-checkin command JSON (matches the pattern the hook looks for)
CANCEL_CMD='{"tool_name":"Bash","tool_input":{"command":"uv run python lib/checkin_scheduler.py cancel --workflow 001-test"}}'
# Non-cancel command JSON
OTHER_CMD='{"tool_name":"Bash","tool_input":{"command":"ls -la"}}'

# ============================================================
# Phase 3: Test PM is blocked from canceling check-ins
# ============================================================
echo "Phase 3: Testing PM is blocked from cancel-checkin..."

PM_OUTPUT=$(run_hook_in_pane "0" "$CANCEL_CMD")
PM_EXIT=$(get_exit_code)

if [[ "$PM_EXIT" == "2" ]]; then
    pass "PM blocked (exit code 2)"
else
    fail "PM NOT blocked (exit code: $PM_EXIT, expected: 2)"
fi

if echo "$PM_OUTPUT" | grep -qi "BLOCKED"; then
    pass "PM received BLOCKED message"
else
    fail "PM missing BLOCKED message"
fi

echo ""

# ============================================================
# Phase 4: Test developer is blocked from canceling check-ins
# ============================================================
echo "Phase 4: Testing developer is blocked from cancel-checkin..."

DEV_OUTPUT=$(run_hook_in_pane "1" "$CANCEL_CMD")
DEV_EXIT=$(get_exit_code)

if [[ "$DEV_EXIT" == "2" ]]; then
    pass "Developer blocked (exit code 2)"
else
    fail "Developer NOT blocked (exit code: $DEV_EXIT, expected: 2)"
fi

echo ""

# ============================================================
# Phase 5: Test QA is blocked from canceling check-ins
# ============================================================
echo "Phase 5: Testing QA is blocked from cancel-checkin..."

QA_OUTPUT=$(run_hook_in_pane "2" "$CANCEL_CMD")
QA_EXIT=$(get_exit_code)

if [[ "$QA_EXIT" == "2" ]]; then
    pass "QA blocked (exit code 2)"
else
    fail "QA NOT blocked (exit code: $QA_EXIT, expected: 2)"
fi

echo ""

# ============================================================
# Phase 6: Test user (no matching identity) is allowed
# ============================================================
echo "Phase 6: Testing user (no matching identity) is allowed..."

USER_OUTPUT=$(run_hook_in_pane "3" "$CANCEL_CMD")
USER_EXIT=$(get_exit_code)

if [[ "$USER_EXIT" == "0" ]]; then
    pass "User allowed (exit code 0)"
else
    fail "User blocked unexpectedly (exit code: $USER_EXIT, expected: 0)"
fi

echo ""

# ============================================================
# Phase 7: Test non-cancel commands are allowed for agents
# ============================================================
echo "Phase 7: Testing non-cancel commands are allowed for agents..."

OTHER_OUTPUT=$(run_hook_in_pane "0" "$OTHER_CMD")
OTHER_EXIT=$(get_exit_code)

if [[ "$OTHER_EXIT" == "0" ]]; then
    pass "PM allowed for non-cancel-checkin commands"
else
    fail "PM blocked from regular command (exit code: $OTHER_EXIT)"
fi

echo ""

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    exit 1
fi
