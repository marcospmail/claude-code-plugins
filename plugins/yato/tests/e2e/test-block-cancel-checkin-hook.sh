#!/bin/bash
# test-block-cancel-checkin-hook.sh
#
# E2E Test: Verify cancel-checkin.sh is blocked for ALL agents
#
# Tests through Claude Code in real tmux sessions:
# 1. Sets up workflow with hooks via init-workflow.sh
# 2. Creates agent identities with real session_ids from tmux
# 3. Simulates the JSON input that Claude Code sends to PreToolUse hooks
# 4. Verifies PM, Developer, and QA are all BLOCKED
# 5. Verifies unknown sessions (user) are ALLOWED
#
# Hook scripts are tested by feeding them JSON input directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-cancel-hook-$TEST_ID"

export TMUX_SOCKET="yato-e2e-test"
SESSION_NAME="e2e-cancel-hook-$TEST_ID"
SESSION_DEV="e2e-cancel-dev-$TEST_ID"
SESSION_QA="e2e-cancel-qa-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: block-cancel-checkin.sh Hook (All Agents Blocked)"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_DEV" 2>/dev/null || true
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_QA" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -f /tmp/e2e-hook-result-$TEST_ID.txt 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test project..."

mkdir -p "$TEST_DIR"
cd "$TEST_DIR" && git init -q && git config user.name "Test" && git config user.email "test@test.com"

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  ✓ Test environment ready"
echo ""

# ============================================================
# PHASE 2: Initialize workflow
# ============================================================
echo "Phase 2: Initializing workflow..."

TMUX_SOCKET="$TMUX_SOCKET" bash "$BIN_DIR/init-workflow.sh" "$TEST_DIR" "test-blocking"

# Find the created workflow
WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
WORKFLOW_NAME=$(basename "$WORKFLOW_DIR")

if [[ -z "$WORKFLOW_DIR" ]] || [[ ! -d "$WORKFLOW_DIR" ]]; then
    echo "FATAL: Workflow not created"
    exit 1
fi

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Create agent sessions and identity files
# ============================================================
echo "Phase 3: Creating tmux sessions for agents..."

# Create extra tmux sessions for dev and QA
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_DEV" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_QA" -x 120 -y 40 -c "$TEST_DIR"

# Get the actual session IDs
PM_SESSION_ID=$(tmux -L "$TMUX_SOCKET" display-message -t "$SESSION_NAME" -p '#{session_id}')
DEV_SESSION_ID=$(tmux -L "$TMUX_SOCKET" display-message -t "$SESSION_DEV" -p '#{session_id}')
QA_SESSION_ID=$(tmux -L "$TMUX_SOCKET" display-message -t "$SESSION_QA" -p '#{session_id}')

echo "  - PM session: $SESSION_NAME (id: $PM_SESSION_ID)"
echo "  - Dev session: $SESSION_DEV (id: $DEV_SESSION_ID)"
echo "  - QA session: $SESSION_QA (id: $QA_SESSION_ID)"

# Create agent identity files
echo "session_id: $PM_SESSION_ID" >> "$WORKFLOW_DIR/agents/pm/identity.yml"

mkdir -p "$WORKFLOW_DIR/agents/developer"
cat > "$WORKFLOW_DIR/agents/developer/identity.yml" <<EOF
name: developer
role: developer
session_id: $DEV_SESSION_ID
EOF

mkdir -p "$WORKFLOW_DIR/agents/qa"
cat > "$WORKFLOW_DIR/agents/qa/identity.yml" <<EOF
name: qa
role: qa
session_id: $QA_SESSION_ID
EOF

echo ""

# ============================================================
# Test 1: Verify hook file was created
# ============================================================
echo "Test 1: Hook file creation..."

HOOK_FILE="$TEST_DIR/.claude/hooks/block-cancel-checkin.sh"

if [[ -f "$HOOK_FILE" ]]; then
    pass "Hook file created at $HOOK_FILE"
else
    fail "Hook file not created"
    exit 1
fi

if [[ -x "$HOOK_FILE" ]]; then
    pass "Hook file is executable"
else
    fail "Hook file is not executable"
fi

# ============================================================
# Test 2: PM is BLOCKED from cancel-checkin.sh
# ============================================================
echo ""
echo "Test 2: PM should be BLOCKED..."

PM_INPUT='{"session_id": "'"$PM_SESSION_ID"'", "tool_input": {"command": "'"$PROJECT_ROOT/bin/cancel-checkin.sh"'"}}'

cd "$TEST_DIR"
RESULT=$(echo "$PM_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "PM blocked (exit code 2)"
else
    fail "PM NOT blocked (exit code: $EXIT_CODE, expected: 2)"
fi

if echo "$RESULT" | grep -qi "BLOCKED"; then
    pass "PM received BLOCKED message"
else
    fail "PM missing BLOCKED message"
fi

# ============================================================
# Test 3: Developer is BLOCKED from cancel-checkin.sh
# ============================================================
echo ""
echo "Test 3: Developer should be BLOCKED..."

DEV_INPUT='{"session_id": "'"$DEV_SESSION_ID"'", "tool_input": {"command": "'"$PROJECT_ROOT/bin/cancel-checkin.sh"'"}}'

cd "$TEST_DIR"
RESULT=$(echo "$DEV_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "Developer blocked (exit code 2)"
else
    fail "Developer NOT blocked (exit code: $EXIT_CODE, expected: 2)"
fi

# ============================================================
# Test 4: QA is BLOCKED from cancel-checkin.sh
# ============================================================
echo ""
echo "Test 4: QA should be BLOCKED..."

QA_INPUT='{"session_id": "'"$QA_SESSION_ID"'", "tool_input": {"command": "'"$PROJECT_ROOT/bin/cancel-checkin.sh"'"}}'

cd "$TEST_DIR"
RESULT=$(echo "$QA_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "QA blocked (exit code 2)"
else
    fail "QA NOT blocked (exit code: $EXIT_CODE, expected: 2)"
fi

# ============================================================
# Test 5: Unknown session (user) is ALLOWED
# ============================================================
echo ""
echo "Test 5: Unknown session (user) should be ALLOWED..."

USER_INPUT='{"session_id": "user-session-unknown-12345", "tool_input": {"command": "'"$PROJECT_ROOT/bin/cancel-checkin.sh"'"}}'

cd "$TEST_DIR"
RESULT=$(echo "$USER_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "User (unknown session) allowed (exit code 0)"
else
    fail "User blocked unexpectedly (exit code: $EXIT_CODE, expected: 0)"
fi

# ============================================================
# Test 6: Agents can run OTHER commands (not blocked)
# ============================================================
echo ""
echo "Test 6: Agents should be ALLOWED for non-cancel-checkin commands..."

PM_OTHER_INPUT='{"session_id": "'"$PM_SESSION_ID"'", "tool_input": {"command": "ls -la"}}'

cd "$TEST_DIR"
RESULT=$(echo "$PM_OTHER_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "PM allowed for non-cancel-checkin commands"
else
    fail "PM blocked from regular command (exit code: $EXIT_CODE)"
fi

# ============================================================
# Test 7: Block message includes agent name
# ============================================================
echo ""
echo "Test 7: Block message should include agent name..."

cd "$TEST_DIR"
RESULT=$(echo "$DEV_INPUT" | bash "$HOOK_FILE" 2>&1)

if echo "$RESULT" | grep -qi "developer"; then
    pass "Block message includes agent name 'developer'"
else
    fail "Block message missing agent name"
fi

# ============================================================
# Test 8: Hook blocks cancel-checkin in compound commands
# ============================================================
echo ""
echo "Test 8: Block cancel-checkin even in compound commands..."

COMPOUND_INPUT='{"session_id": "'"$PM_SESSION_ID"'", "tool_input": {"command": "cd /tmp && '"$PROJECT_ROOT/bin/cancel-checkin.sh"' && echo done"}}'

cd "$TEST_DIR"
RESULT=$(echo "$COMPOUND_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "PM blocked with compound command containing cancel-checkin"
else
    fail "PM NOT blocked with compound command (exit code: $EXIT_CODE)"
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
