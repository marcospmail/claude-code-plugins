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
# Phases 3-6 run the Python hook script directly for reliable output parsing.
# Phase 7 verifies hook works in a real Claude session.

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

pass "Test directory created at $TEST_DIR"
echo ""

# ============================================================
# Phase 3: Test PM - allowed workflow files (direct script execution)
# ============================================================
echo "Phase 3: Testing PM access to allowed workflow files..."

# Test tasks.json (should be allowed)
TASKS_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/.workflow/001-test-workflow/tasks.json"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$TASKS_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit tasks.json"
else
    fail "PM blocked from tasks.json (should be allowed)"
fi

# Test prd.md (should be allowed)
PRD_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/.workflow/001-test-workflow/prd.md"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$PRD_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit prd.md"
else
    fail "PM not allowed to edit prd.md"
fi

# Test status.yml (should be allowed)
STATUS_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/.workflow/001-test-workflow/status.yml"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$STATUS_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit status.yml"
else
    fail "PM not allowed to edit status.yml"
fi

echo ""

# ============================================================
# Phase 4: Test PM - blocked files (direct script execution)
# ============================================================
echo "Phase 4: Testing PM blocked from source code files..."

# Test .py file (should be blocked)
PY_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/src/main.py"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$PY_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing src/main.py"
else
    fail "PM should be blocked from src/main.py"
fi

# Test file outside project (should be blocked)
TMP_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"/tmp/random-file.txt"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$TMP_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing /tmp/random-file.txt"
else
    fail "PM should be blocked from files outside project"
fi

# Test config file in project root (should be blocked)
PKG_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/package.json"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$PKG_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing package.json"
else
    fail "PM should be blocked from package.json"
fi

echo ""

# ============================================================
# Phase 5: Test non-PM agent - should have full access (direct script execution)
# ============================================================
echo "Phase 5: Testing non-PM agent (developer) has full access..."

# Test .py file as developer (should be allowed)
DEV_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/src/main.py"}}' | AGENT_ROLE=developer uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$DEV_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Developer allowed to edit src/main.py"
else
    fail "Developer should be allowed to edit src/main.py"
fi

# Test with no role set (should be allowed)
NOROLE_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/src/main.py"}}' | AGENT_ROLE='' TMUX='' uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)
if echo "$NOROLE_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "No role set - allowed to edit src/main.py"
else
    fail "No role set - should be allowed (not PM context)"
fi

echo ""

# ============================================================
# Phase 6: Test block message content (direct script execution)
# ============================================================
echo "Phase 6: Testing block message content..."

BLOCK_OUTPUT=$(cd "$TEST_DIR" && echo '{"tool_input":{"file_path":"'"$TEST_DIR"'/src/main.py"}}' | AGENT_ROLE=pm uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>&1)

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
