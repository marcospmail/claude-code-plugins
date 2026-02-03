#!/bin/bash
# test-block-cancel-checkin-hook.sh
#
# E2E Test: Verify cancel-checkin.sh is blocked for ALL agents
#
# Tests through real tmux sessions:
# 1. Sets up workflow with hooks via init-workflow.sh
# 2. Creates agent identities with real session_ids from tmux
# 3. Simulates the JSON input that Claude Code sends to PreToolUse hooks
# 4. Verifies PM, Developer, and QA are all BLOCKED
# 5. Verifies unknown sessions (user) are ALLOWED

# Note: Don't use set -e as test failures should be counted, not exit immediately

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
BIN_DIR="$PROJECT_ROOT/bin"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-cancel-hook-$TEST_ID"

# Session names
SESSION_PM="e2e-cancel-pm-$TEST_ID"
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

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$SESSION_PM" 2>/dev/null || true
    tmux kill-session -t "$SESSION_DEV" 2>/dev/null || true
    tmux kill-session -t "$SESSION_QA" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project with workflow
# ============================================================

echo "Setting up test project..."
mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init -q
git config user.name "Test"
git config user.email "test@test.com"

# Initialize workflow with hooks
"$BIN_DIR/init-workflow.sh" "$TEST_DIR" "test-blocking" > /dev/null

# Find the created workflow
WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
WORKFLOW_NAME=$(basename "$WORKFLOW_DIR")

if [[ -z "$WORKFLOW_DIR" ]] || [[ ! -d "$WORKFLOW_DIR" ]]; then
    echo "FATAL: Workflow not created"
    exit 1
fi

echo "  Workflow: $WORKFLOW_NAME"

# ============================================================
# Setup: Create tmux sessions for each agent
# ============================================================

echo ""
echo "Creating tmux sessions for agents..."

# Create tmux sessions
tmux new-session -d -s "$SESSION_PM" -c "$TEST_DIR"
tmux new-session -d -s "$SESSION_DEV" -c "$TEST_DIR"
tmux new-session -d -s "$SESSION_QA" -c "$TEST_DIR"

# Get the actual session IDs that tmux uses
PM_SESSION_ID=$(tmux display-message -t "$SESSION_PM" -p '#{session_id}')
DEV_SESSION_ID=$(tmux display-message -t "$SESSION_DEV" -p '#{session_id}')
QA_SESSION_ID=$(tmux display-message -t "$SESSION_QA" -p '#{session_id}')

echo "  PM session: $SESSION_PM (id: $PM_SESSION_ID)"
echo "  Dev session: $SESSION_DEV (id: $DEV_SESSION_ID)"
echo "  QA session: $SESSION_QA (id: $QA_SESSION_ID)"

# ============================================================
# Setup: Create agent identity files with session_ids
# ============================================================

echo ""
echo "Creating agent identity files..."

# PM identity (already created by init-workflow.sh, just add session_id)
echo "session_id: $PM_SESSION_ID" >> "$WORKFLOW_DIR/agents/pm/identity.yml"

# Create developer agent
mkdir -p "$WORKFLOW_DIR/agents/developer"
cat > "$WORKFLOW_DIR/agents/developer/identity.yml" <<EOF
name: developer
role: developer
session_id: $DEV_SESSION_ID
EOF

# Create QA agent
mkdir -p "$WORKFLOW_DIR/agents/qa"
cat > "$WORKFLOW_DIR/agents/qa/identity.yml" <<EOF
name: qa
role: qa
session_id: $QA_SESSION_ID
EOF

# ============================================================
# Test 1: Verify hook file was created
# ============================================================

echo ""
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

# Simulate Claude Code's PreToolUse JSON input
PM_INPUT=$(cat <<EOF
{
  "session_id": "$PM_SESSION_ID",
  "tool_input": {
    "command": "$PROJECT_ROOT/bin/cancel-checkin.sh"
  }
}
EOF
)

# Run hook from within the PM's tmux session context
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

DEV_INPUT=$(cat <<EOF
{
  "session_id": "$DEV_SESSION_ID",
  "tool_input": {
    "command": "$PROJECT_ROOT/bin/cancel-checkin.sh"
  }
}
EOF
)

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

QA_INPUT=$(cat <<EOF
{
  "session_id": "$QA_SESSION_ID",
  "tool_input": {
    "command": "$PROJECT_ROOT/bin/cancel-checkin.sh"
  }
}
EOF
)

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

USER_INPUT=$(cat <<EOF
{
  "session_id": "user-session-unknown-12345",
  "tool_input": {
    "command": "$PROJECT_ROOT/bin/cancel-checkin.sh"
  }
}
EOF
)

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

PM_OTHER_INPUT=$(cat <<EOF
{
  "session_id": "$PM_SESSION_ID",
  "tool_input": {
    "command": "ls -la"
  }
}
EOF
)

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

COMPOUND_INPUT=$(cat <<EOF
{
  "session_id": "$PM_SESSION_ID",
  "tool_input": {
    "command": "cd /tmp && $PROJECT_ROOT/bin/cancel-checkin.sh && echo done"
  }
}
EOF
)

cd "$TEST_DIR"
RESULT=$(echo "$COMPOUND_INPUT" | bash "$HOOK_FILE" 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "PM blocked with compound command containing cancel-checkin"
else
    fail "PM NOT blocked with compound command (exit code: $EXIT_CODE)"
fi

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
