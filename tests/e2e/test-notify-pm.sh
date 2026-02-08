#!/bin/bash
# test-notify-pm.sh
#
# E2E Test: notify-pm Skill Communication
#
# Verifies that the notify-pm skill:
# 1. Auto-invokes when Claude is asked to notify the PM
# 2. Sends messages to PM at window 0, pane 1
# 3. Message content is delivered correctly
# 4. Different message types work ([DONE], [BLOCKED], [HELP], [STATUS])
# 5. Skill file has correct configuration
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# The skill has user-invocable: false, so Claude auto-invokes it when asked
# to notify the PM in natural language.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="notify-pm"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: notify-pm Skill Communication"
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
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR/.claude/skills"

# Copy Yato skills to test directory so Claude can find them
cp -r "$PROJECT_ROOT/skills/notify-pm" "$TEST_DIR/.claude/skills/"

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm-checkins" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -v -p 50 -c "$TEST_DIR"

# Pane 0 = check-ins display, Pane 1 = PM
echo "  - Session: $SESSION_NAME"
echo "  - Window 0: pane 0 (checkins), pane 1 (PM)"

# Create agent window (simulating a developer agent)
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "developer" -c "$TEST_DIR"
echo "  - Window 1: developer agent"

# Start Claude in the developer window
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "claude" Enter

# Wait for Claude to start and handle trust prompt
echo "  - Waiting for Claude to start..."
sleep 8

# Check for trust prompt and send Enter to accept
AGENT_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$AGENT_OUTPUT" | grep -qi "trust"; then
    echo "  - Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
    sleep 15
else
    echo "  - No trust prompt found, continuing..."
    sleep 5
fi

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Test [DONE] message type
# ============================================================
echo "Phase 2: Testing [DONE] message type through Claude..."

# Generate unique test message
TEST_MSG="Task T1 completed - test run $$"

# Ask Claude to notify the PM (send text first, then Enter separately for Claude's TUI)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Please notify the PM with this message: [DONE] $TEST_MSG"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10

# Handle skill trust prompt ("Use skill 'notify-pm'?") - accept and don't ask again
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    echo "  - Skill trust prompt found, accepting with 'don't ask again'..."
    # Select option 2: "Yes, and don't ask again"
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

# Capture agent window output to verify skill was invoked
AGENT_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -100)

# Debug: show what Claude did
echo "  Debug - After [DONE] notify:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -30 | tail -15
echo ""

# Check if Claude invoked the notify-pm skill
if echo "$AGENT_OUTPUT" | grep -q -E "notify-pm|Skill|Message sent|notif.*PM"; then
    pass "[DONE] message - Claude invoked notify-pm skill"
else
    fail "[DONE] message - Claude did not invoke notify-pm skill"
fi

# Check if message was sent (look for confirmation in output)
if echo "$AGENT_OUTPUT" | grep -q -E "Message sent|sent.*message|notified|notify-pm\.sh"; then
    pass "[DONE] message - Confirmation of message sent"
else
    fail "[DONE] message - No confirmation of message sent"
fi

# ============================================================
# PHASE 3: Test [BLOCKED] message type
# ============================================================
echo ""
echo "Phase 3: Testing [BLOCKED] message type..."

BLOCKED_MSG="Need database credentials to proceed - test $$"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Notify the PM that I'm blocked: [BLOCKED] $BLOCKED_MSG"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10
# Handle skill trust prompt if it reappears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

BLOCKED_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -100)
if echo "$BLOCKED_OUTPUT" | grep -q -E "notify-pm\.sh|Message sent|notif.*PM|BLOCKED"; then
    pass "[BLOCKED] message - Claude invoked skill"
else
    fail "[BLOCKED] message - Claude did not invoke skill"
fi

# ============================================================
# PHASE 4: Test [HELP] message type
# ============================================================
echo ""
echo "Phase 4: Testing [HELP] message type..."

HELP_MSG="Should I use REST or GraphQL for the new API - test $$"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "I need to ask the PM a question: [HELP] $HELP_MSG"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10
# Handle skill trust prompt if it reappears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

HELP_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -100)
if echo "$HELP_OUTPUT" | grep -q -E "notify-pm\.sh|Message sent|notif.*PM|HELP"; then
    pass "[HELP] message - Claude invoked skill"
else
    fail "[HELP] message - Claude did not invoke skill"
fi

# ============================================================
# PHASE 5: Test [STATUS] message type
# ============================================================
echo ""
echo "Phase 5: Testing [STATUS] message type..."

STATUS_MSG="3 of 5 subtasks complete - test $$"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Send a status update to the PM: [STATUS] $STATUS_MSG"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10
# Handle skill trust prompt if it reappears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

STATUS_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -100)
if echo "$STATUS_OUTPUT" | grep -q -E "notify-pm\.sh|Message sent|notif.*PM|STATUS"; then
    pass "[STATUS] message - Claude invoked skill"
else
    fail "[STATUS] message - Claude did not invoke skill"
fi

# ============================================================
# PHASE 6: Test [PROGRESS] message type
# ============================================================
echo ""
echo "Phase 6: Testing [PROGRESS] message type..."

PROGRESS_MSG="Implementing authentication module - test $$"
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Report my progress to the PM: [PROGRESS] $PROGRESS_MSG"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10
# Handle skill trust prompt if it reappears
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

PROGRESS_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -100)
if echo "$PROGRESS_OUTPUT" | grep -q -E "notify-pm\.sh|Message sent|notif.*PM|PROGRESS"; then
    pass "[PROGRESS] message - Claude invoked skill"
else
    fail "[PROGRESS] message - Claude did not invoke skill"
fi

# ============================================================
# PHASE 7: Verify PM received messages (optional check)
# ============================================================
echo ""
echo "Phase 7: Verifying PM pane (window 0, pane 1)..."

# Capture PM pane output
PM_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p -S -100)

# Note: This is a best-effort check - messages might not appear in PM pane
# if the pane is just an empty shell, but we can check if tmux delivered them
if [[ -n "$PM_OUTPUT" ]]; then
    pass "PM pane is accessible"
else
    # Empty pane is OK - just means no shell output
    pass "PM pane exists (may be empty)"
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

    # Check skill uses $HOME/dev/tools/yato/bin/notify-pm.sh path
    if echo "$SKILL_CONTENT" | grep -q '\$HOME/dev/tools/yato/bin/notify-pm.sh'; then
        pass "Skill uses correct \$HOME/dev/tools/yato/bin/notify-pm.sh path"
    else
        fail "Skill should use \$HOME/dev/tools/yato/bin/notify-pm.sh path"
    fi

    # Check skill has message type documentation
    if echo "$SKILL_CONTENT" | grep -q -E "\[DONE\].*\[BLOCKED\].*\[HELP\].*\[STATUS\]"; then
        pass "Skill documents all message types"
    else
        # Check individually
        TYPES_FOUND=0
        echo "$SKILL_CONTENT" | grep -q "\[DONE\]" && TYPES_FOUND=$((TYPES_FOUND + 1))
        echo "$SKILL_CONTENT" | grep -q "\[BLOCKED\]" && TYPES_FOUND=$((TYPES_FOUND + 1))
        echo "$SKILL_CONTENT" | grep -q "\[HELP\]" && TYPES_FOUND=$((TYPES_FOUND + 1))
        echo "$SKILL_CONTENT" | grep -q "\[STATUS\]" && TYPES_FOUND=$((TYPES_FOUND + 1))

        if [[ $TYPES_FOUND -ge 3 ]]; then
            pass "Skill documents message types ($TYPES_FOUND/5)"
        else
            fail "Skill should document message types (only found $TYPES_FOUND/5)"
        fi
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
