#!/bin/bash
# test-notify-pm.sh
#
# E2E Test: notify-pm Script Communication
#
# Verifies that the notify-pm script:
# 1. Sends messages to PM at window 0, pane 1
# 2. Different message types work ([DONE], [BLOCKED], [HELP], [STATUS], [PROGRESS])
# 3. PM pane receives the actual message content
# 4. Skill file has correct configuration
#
# Tests notify-pm.sh directly (not through Claude) to verify message delivery.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="notify-pm"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-hook-output-$TEST_NAME-$$"
MAX_WAIT=15

echo "======================================================================"
echo "  E2E Test: notify-pm Script Communication"
echo "======================================================================"
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
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: run notify-pm.sh from agent window and wait for completion
run_notify() {
    local msg_type="$1"
    local msg_body="$2"

    rm -f "$OUTPUT_FILE"

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" \
        "TMUX_SOCKET='$TMUX_SOCKET' '$PROJECT_ROOT/bin/notify-pm.sh' '[$msg_type] $msg_body' > '$OUTPUT_FILE' 2>&1 && echo NOTIFY_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

    local waited=0
    while [[ $waited -lt $MAX_WAIT ]]; do
        if [[ -f "$OUTPUT_FILE" ]] && grep -q "NOTIFY_DONE" "$OUTPUT_FILE" 2>/dev/null; then
            cat "$OUTPUT_FILE"
            return 0
        fi
        sleep 1
        waited=$((waited + 1))
    done
    echo "TIMEOUT"
    return 1
}

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

# Create tmux session: window 0 with PM pane layout, window 1 for agent
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm-checkins" -c "$TEST_DIR"
PM_PANE_ID=$(tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -v -p 50 -c "$TEST_DIR" -P -F '#{pane_id}')

# Pane 0 = check-ins display, Pane 1 = PM (identified by pane_id)
echo "  - Session: $SESSION_NAME"
echo "  - Window 0: pane 0 (checkins), pane 1 (PM, pane_id=$PM_PANE_ID)"

# Create agent window (simulating a developer agent)
DEV_PANE_ID=$(tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "developer" -c "$TEST_DIR" -P -F '#{pane_id}')
echo "  - Window 1: developer agent (pane_id=$DEV_PANE_ID)"

sleep 2

# Create workflow dir with agents.yml so notify_pm can find PM pane_id
mkdir -p "$TEST_DIR/.workflow/001-test-notify"
cat > "$TEST_DIR/.workflow/001-test-notify/agents.yml" << EOF
pm:
  name: PM
  role: pm
  pane_id: "$PM_PANE_ID"
  session: $SESSION_NAME
  window: 0
  model: opus
agents:
  - name: developer
    role: developer
    pane_id: "$DEV_PANE_ID"
    session: $SESSION_NAME
    window: 1
    model: sonnet
EOF
cat > "$TEST_DIR/.workflow/001-test-notify/status.yml" << EOF
status: in-progress
EOF
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-notify

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Test [DONE] message type
# ============================================================
echo "Phase 2: Testing [DONE] message type..."

DONE_MSG="Task T1 completed - test run $TEST_NAME-$$"
DONE_OUTPUT=$(run_notify "DONE" "$DONE_MSG")

if echo "$DONE_OUTPUT" | grep -q "Message sent\|Notification sent"; then
    pass "[DONE] message - notify-pm.sh confirmed delivery"
else
    fail "[DONE] message - notify-pm.sh did not confirm delivery"
fi

# ============================================================
# PHASE 3: Test [BLOCKED] message type
# ============================================================
echo ""
echo "Phase 3: Testing [BLOCKED] message type..."

BLOCKED_MSG="Need database credentials - test $TEST_NAME-$$"
BLOCKED_OUTPUT=$(run_notify "BLOCKED" "$BLOCKED_MSG")

if echo "$BLOCKED_OUTPUT" | grep -q "Message sent\|Notification sent"; then
    pass "[BLOCKED] message - notify-pm.sh confirmed delivery"
else
    fail "[BLOCKED] message - notify-pm.sh did not confirm delivery"
fi

# ============================================================
# PHASE 4: Test [HELP] message type
# ============================================================
echo ""
echo "Phase 4: Testing [HELP] message type..."

HELP_MSG="Should I use REST or GraphQL - test $TEST_NAME-$$"
HELP_OUTPUT=$(run_notify "HELP" "$HELP_MSG")

if echo "$HELP_OUTPUT" | grep -q "Message sent\|Notification sent"; then
    pass "[HELP] message - notify-pm.sh confirmed delivery"
else
    fail "[HELP] message - notify-pm.sh did not confirm delivery"
fi

# ============================================================
# PHASE 5: Test [STATUS] message type
# ============================================================
echo ""
echo "Phase 5: Testing [STATUS] message type..."

STATUS_MSG="3 of 5 subtasks complete - test $TEST_NAME-$$"
STATUS_OUTPUT=$(run_notify "STATUS" "$STATUS_MSG")

if echo "$STATUS_OUTPUT" | grep -q "Message sent\|Notification sent"; then
    pass "[STATUS] message - notify-pm.sh confirmed delivery"
else
    fail "[STATUS] message - notify-pm.sh did not confirm delivery"
fi

# ============================================================
# PHASE 6: Test [PROGRESS] message type
# ============================================================
echo ""
echo "Phase 6: Testing [PROGRESS] message type..."

PROGRESS_MSG="Implementing authentication module - test $TEST_NAME-$$"
PROGRESS_OUTPUT=$(run_notify "PROGRESS" "$PROGRESS_MSG")

if echo "$PROGRESS_OUTPUT" | grep -q "Message sent\|Notification sent"; then
    pass "[PROGRESS] message - notify-pm.sh confirmed delivery"
else
    fail "[PROGRESS] message - notify-pm.sh did not confirm delivery"
fi

# ============================================================
# PHASE 7: Verify PM pane received messages
# ============================================================
echo ""
echo "Phase 7: Verifying PM pane (window 0, pane 1) received messages..."

sleep 2

# Capture PM pane output
PM_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p -S -1000 2>/dev/null)

# Check for the unique test ID in PM pane — proves messages were actually delivered
if echo "$PM_OUTPUT" | grep -q "$TEST_NAME-$$"; then
    pass "PM pane received messages (unique test ID found)"
else
    fail "PM pane did not receive messages (test ID '$TEST_NAME-$$' not found)"
fi

# Check specific message body content was delivered to PM pane
# Note: [DONE] and [BLOCKED] may be mangled by zsh glob expansion, so check body text
if echo "$PM_OUTPUT" | grep -q "Task T1 completed"; then
    pass "PM pane received [DONE] message body"
else
    fail "PM pane missing [DONE] message body"
fi

if echo "$PM_OUTPUT" | grep -q "database credentials"; then
    pass "PM pane received [BLOCKED] message body"
else
    fail "PM pane missing [BLOCKED] message body"
fi

# ============================================================
# PHASE 8: Verify skill file configuration
# ============================================================
echo ""
echo "Phase 8: Verifying notify-pm skill configuration..."

SKILL_FILE="$PROJECT_ROOT/skills/notify-pm/SKILL.md"

# Check skill file exists
if [[ -f "$SKILL_FILE" ]]; then
    pass "Skill file exists at skills/notify-pm/SKILL.md"
else
    fail "Skill file missing at skills/notify-pm/SKILL.md"
fi

# Check skill has correct configuration
if [[ -f "$SKILL_FILE" ]]; then
    SKILL_CONTENT=$(cat "$SKILL_FILE")

    # Check user-invocable: false (agents invoke via natural language)
    if echo "$SKILL_CONTENT" | grep -q "user-invocable: false"; then
        pass "Skill has user-invocable: false (correct)"
    else
        fail "Skill should have user-invocable: false"
    fi

    # Check disable-model-invocation: false (Claude can auto-invoke)
    if echo "$SKILL_CONTENT" | grep -q "disable-model-invocation: false"; then
        pass "Skill has disable-model-invocation: false (correct)"
    else
        fail "Skill should have disable-model-invocation: false"
    fi

    # Check skill uses ${CLAUDE_PLUGIN_ROOT}/bin/notify-pm.sh path
    if echo "$SKILL_CONTENT" | grep -q 'CLAUDE_PLUGIN_ROOT.*/bin/notify-pm.sh'; then
        pass "Skill uses correct \${CLAUDE_PLUGIN_ROOT}/bin/notify-pm.sh path"
    else
        fail "Skill should use \${CLAUDE_PLUGIN_ROOT}/bin/notify-pm.sh path"
    fi

    # Check skill has message type documentation
    TYPES_FOUND=0
    echo "$SKILL_CONTENT" | grep -q "\[DONE\]" && TYPES_FOUND=$((TYPES_FOUND + 1))
    echo "$SKILL_CONTENT" | grep -q "\[BLOCKED\]" && TYPES_FOUND=$((TYPES_FOUND + 1))
    echo "$SKILL_CONTENT" | grep -q "\[HELP\]" && TYPES_FOUND=$((TYPES_FOUND + 1))
    echo "$SKILL_CONTENT" | grep -q "\[STATUS\]" && TYPES_FOUND=$((TYPES_FOUND + 1))

    if [[ $TYPES_FOUND -ge 3 ]]; then
        pass "Skill documents message types ($TYPES_FOUND/4)"
    else
        fail "Skill should document message types (only found $TYPES_FOUND/4)"
    fi

    # Check skill description mentions agents only
    if echo "$SKILL_CONTENT" | grep -q "Only for agents.*NOT for PM"; then
        pass "Skill description correctly states it's for agents only"
    else
        fail "Skill should state it's only for agents, not PM"
    fi
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
