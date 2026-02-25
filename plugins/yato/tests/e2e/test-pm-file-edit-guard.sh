#!/bin/bash
# test-pm-file-edit-guard.sh
#
# E2E Test: PreToolUse hook that restricts PM file edit
#
# This test verifies:
# 1. Hook is registered in hooks.json
# 2. Hook allows PM to edit workflow files (tasks.json, prd.md, etc.)
# 3. Hook blocks PM from editing source code files
# 4. Hook blocks PM from editing files outside .workflow/
# 5. Hook allows non-PM agents to edit any files
# 6. Block message content is correct
#
# All tests use tmux-based workflow detection (agents.yml + pane matching).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-file-access"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-pm-access-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-hook-output-$TEST_NAME-$TEST_ID"
MAX_WAIT=30

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
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/pm-file-edit-guard.py"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

# Helper: run hook from a tmux pane and capture output
run_hook_in_pane() {
    local pane="$1"
    local file_path="$2"

    rm -f "$OUTPUT_FILE"

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:$pane" \
        "echo '{\"tool_input\":{\"file_path\":\"$file_path\"}}' | HOOK_CWD='$TEST_DIR' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

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

if jq -e '.hooks.PreToolUse[0].hooks[] | select(.command | contains("pm-file-edit-guard.py"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "PreToolUse hook configured for pm-file-edit-guard.py"
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
mkdir -p "$TEST_DIR/src"

# Create agents.yml: PM at window 0 pane 0, developer at window 1
cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << EOF
pm:
  name: PM
  role: pm
  session: $SESSION_NAME
  window: 0
  pane: 0
  model: opus
agents:
  - name: developer
    role: developer
    session: $SESSION_NAME
    window: 1
    model: opus
EOF

# Create identity.yml files (used by role detection)
cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
window: 0
session: $SESSION_NAME
workflow: 001-test-workflow
can_modify_code: false
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/developer/identity.yml" << EOF
name: developer
role: developer
model: opus
window: 1
session: $SESSION_NAME
workflow: 001-test-workflow
can_modify_code: true
EOF

# Create workflow files
echo '{"tasks": []}' > "$TEST_DIR/.workflow/001-test-workflow/tasks.json"
echo '# Test PRD' > "$TEST_DIR/.workflow/001-test-workflow/prd.md"
echo 'status: in-progress' > "$TEST_DIR/.workflow/001-test-workflow/status.yml"

# Create source file (should be blocked for PM)
echo 'print("Hello")' > "$TEST_DIR/src/main.py"
echo '{}' > "$TEST_DIR/package.json"

# Create tmux session with PM at window 0, developer at window 1
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow
# Create window 1 for developer
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
# Create window 2 (unmatched - no agent)
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
sleep 2

pass "Test directory and tmux session created"
echo ""

# ============================================================
# Phase 3: Test PM - allowed workflow files (via tmux pane detection)
# ============================================================
echo "Phase 3: Testing PM access to allowed workflow files..."

# Test tasks.json (should be allowed)
TASKS_OUTPUT=$(run_hook_in_pane "0" "$TEST_DIR/.workflow/001-test-workflow/tasks.json")
if echo "$TASKS_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit tasks.json"
else
    fail "PM blocked from tasks.json (should be allowed)"
fi

# Test prd.md (should be allowed)
PRD_OUTPUT=$(run_hook_in_pane "0" "$TEST_DIR/.workflow/001-test-workflow/prd.md")
if echo "$PRD_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit prd.md"
else
    fail "PM not allowed to edit prd.md"
fi

# Test status.yml (should be allowed)
STATUS_OUTPUT=$(run_hook_in_pane "0" "$TEST_DIR/.workflow/001-test-workflow/status.yml")
if echo "$STATUS_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed to edit status.yml"
else
    fail "PM not allowed to edit status.yml"
fi

echo ""

# ============================================================
# Phase 4: Test PM - blocked files (via tmux pane detection)
# ============================================================
echo "Phase 4: Testing PM blocked from source code files..."

# Test .py file (should be blocked)
PY_OUTPUT=$(run_hook_in_pane "0" "$TEST_DIR/src/main.py")
if echo "$PY_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing src/main.py"
else
    fail "PM should be blocked from src/main.py"
fi

# Test file outside project (should be blocked)
TMP_OUTPUT=$(run_hook_in_pane "0" "/tmp/random-file.txt")
if echo "$TMP_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing /tmp/random-file.txt"
else
    fail "PM should be blocked from files outside project"
fi

# Test config file in project root (should be blocked)
PKG_OUTPUT=$(run_hook_in_pane "0" "$TEST_DIR/package.json")
if echo "$PKG_OUTPUT" | grep -q '"block"'; then
    pass "PM blocked from editing package.json"
else
    fail "PM should be blocked from package.json"
fi

echo ""

# ============================================================
# Phase 5: Test non-PM agent - should have full access (via tmux pane detection)
# ============================================================
echo "Phase 5: Testing non-PM agent (developer) has full access..."

# Test .py file as developer from window 1 (should be allowed)
DEV_OUTPUT=$(run_hook_in_pane "1" "$TEST_DIR/src/main.py")
if echo "$DEV_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Developer allowed to edit src/main.py"
else
    fail "Developer should be allowed to edit src/main.py"
fi

# Test with no role (unmatched window 2 - should be allowed)
NOROLE_OUTPUT=$(run_hook_in_pane "2" "$TEST_DIR/src/main.py")
if echo "$NOROLE_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "No role set - allowed to edit src/main.py"
else
    fail "No role set - should be allowed (not PM context)"
fi

echo ""

# ============================================================
# Phase 6: Test block message content (via tmux pane detection)
# ============================================================
echo "Phase 6: Testing block message content..."

BLOCK_OUTPUT=$(run_hook_in_pane "0" "$TEST_DIR/src/main.py")

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
# Phase 7: Test invalid JSON stdin returns safe fallback
# ============================================================
echo "Phase 7: Testing invalid JSON stdin returns safe fallback..."

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" \
    "echo 'not valid json' | uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

INVALID_OUTPUT=$(cat "$OUTPUT_FILE" 2>/dev/null)

if echo "$INVALID_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Invalid JSON returns safe fallback {continue: true}"
else
    fail "Invalid JSON should return safe fallback"
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
