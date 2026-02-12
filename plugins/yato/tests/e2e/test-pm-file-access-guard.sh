#!/bin/bash
# test-pm-file-access-guard.sh
#
# E2E Test: PreToolUse hook that restricts PM file access
#
# This test verifies:
# 1. Hook is registered in hooks.json
# 2. Hook allows PM to edit workflow files (tasks.json, prd.md, etc.)
# 3. Hook blocks PM from editing source code files
# 4. Hook blocks PM from editing files outside .workflow/
# 5. Hook allows non-PM agents to edit any files
# 6. Block message content is correct
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-file-access"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-pm-access-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: PM File Access Guard Hook"
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
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/pm-file-access-guard.py"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

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

if jq -e '.hooks.PreToolUse[0].hooks[] | select(.command | contains("pm-file-access-guard.py"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "PreToolUse hook configured for pm-file-access-guard.py"
else
    fail "PreToolUse hook not configured correctly in hooks.json"
    exit 1
fi

echo ""

# ============================================================
# Phase 2: Setup test environment
# ============================================================
echo "Phase 2: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/developer"
mkdir -p "$TEST_DIR/src"

# Create workflow files
echo '{"tasks": []}' > "$TEST_DIR/.workflow/001-test-workflow/tasks.json"
echo '# Test PRD' > "$TEST_DIR/.workflow/001-test-workflow/prd.md"
echo 'status: in-progress' > "$TEST_DIR/.workflow/001-test-workflow/status.yml"

# Create source file (should be blocked for PM)
echo 'print("Hello")' > "$TEST_DIR/src/main.py"
echo '{}' > "$TEST_DIR/package.json"

# Create agent identity
mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/dev"
echo "role: developer" > "$TEST_DIR/.workflow/001-test-workflow/agents/dev/identity.yml"

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" AGENT_ROLE "pm"

if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    pass "Tmux session created with AGENT_ROLE=pm"
else
    fail "Failed to create tmux session"
    exit 1
fi

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

echo "  Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  No trust prompt found, continuing..."
    sleep 5
fi

echo "  Test directory: $TEST_DIR"
echo "  Test environment ready"
echo ""

# ============================================================
# Phase 3: Test PM - allowed workflow files
# ============================================================
echo "Phase 3: Testing PM access to allowed workflow files..."

# Test tasks.json (should be allowed)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

TASKS_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$TASKS_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit tasks.json"
else
    fail "PM blocked from tasks.json (should be allowed)"
fi

# Test prd.md (should be allowed)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/prd.md\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

PRD_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$PRD_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit prd.md"
else
    fail "PM not allowed to edit prd.md"
fi

# Test status.yml (should be allowed)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/status.yml\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

STATUS_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$STATUS_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit status.yml"
else
    fail "PM not allowed to edit status.yml"
fi

echo ""

# ============================================================
# Phase 4: Test PM - blocked files
# ============================================================
echo "Phase 4: Testing PM blocked from source code files..."

# Test .py file (should be blocked)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

PY_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$PY_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing src/main.py"
else
    fail "PM should be blocked from src/main.py"
fi

# Test file outside project (should be blocked)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"/tmp/random-file.txt\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

TMP_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$TMP_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing /tmp/random-file.txt"
else
    fail "PM should be blocked from files outside project"
fi

# Test config file in project root (should be blocked)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/package.json\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

PKG_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$PKG_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing package.json"
else
    fail "PM should be blocked from package.json"
fi

echo ""

# ============================================================
# Phase 5: Test non-PM agent - should have full access
# ============================================================
echo "Phase 5: Testing non-PM agent (developer) has full access..."

# Test .py file as developer (should be allowed)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | AGENT_ROLE=developer uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

DEV_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$DEV_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Developer allowed to edit src/main.py"
else
    fail "Developer should be allowed to edit src/main.py"
fi

# Test with no role set (should be allowed)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | AGENT_ROLE='' TMUX='' uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

NOROLE_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 2>/dev/null)
if echo "$NOROLE_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "No role set - allowed to edit src/main.py"
else
    fail "No role set - should be allowed (not PM context)"
fi

echo ""

# ============================================================
# Phase 6: Test block message content
# ============================================================
echo "Phase 6: Testing block message content..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | AGENT_ROLE=pm uv run python '$HOOK_SCRIPT' 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 10

SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter
    sleep 20
else
    sleep 20
fi

BLOCK_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

if echo "$BLOCK_OUTPUT" | grep -qi "PM FILE ACCESS DENIED"; then
    pass "Block reason contains 'PM FILE ACCESS DENIED'"
else
    fail "Block reason should mention access denied"
fi

if echo "$BLOCK_OUTPUT" | grep -qi "delegate"; then
    pass "Block reason mentions delegation"
else
    fail "Block reason should mention delegation"
fi

echo ""

# ============================================================
# Results
# ============================================================
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
