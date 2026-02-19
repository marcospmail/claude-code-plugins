#!/bin/bash
# test-pm-bash-allowlist.sh
#
# E2E Test: PreToolUse hook that restricts PM to an allowlist of Bash commands
#
# This test verifies:
# 1. Hook is registered in hooks.json with Bash matcher
# 2. PM is allowed to run read-only commands (grep, ls, git status, etc.)
# 3. PM is blocked from running file-modifying commands (echo, sed, python3, etc.)
# 4. Non-PM agents (developer) are allowed to run any command
# 5. User/orchestrator (no role) is allowed to run any command
# 6. Git read-only subcommands allowed, write subcommands blocked
# 7. Chained commands: blocked if any segment uses a blocked binary
# 8. Invalid JSON stdin returns safe fallback
#
# All tests use tmux-based workflow detection (identity.yml + session/window matching).

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-bash-allowlist"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-bash-allow-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-hook-output-$TEST_NAME-$TEST_ID"
INPUT_CMD_FILE="/tmp/e2e-hook-cmd-$TEST_NAME-$TEST_ID"
INPUT_JSON_FILE="/tmp/e2e-hook-input-$TEST_NAME-$TEST_ID"
MAX_WAIT=30

echo "======================================================================"
echo "  E2E Test: PM Bash Allowlist Hook"
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
    rm -f "$OUTPUT_FILE" "$INPUT_CMD_FILE" "$INPUT_JSON_FILE" 2>/dev/null || true
}
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/pm-bash-allowlist.py"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

# Helper: run hook from a tmux pane with a given command and capture output
run_hook_in_pane() {
    local pane="$1"
    local cmd="$2"

    rm -f "$OUTPUT_FILE"

    # Write command to temp file, then build JSON safely with Python
    printf '%s' "$cmd" > "$INPUT_CMD_FILE"
    python3 -c "
import json
cmd = open('$INPUT_CMD_FILE').read()
print(json.dumps({'tool_input': {'command': cmd}}))
" > "$INPUT_JSON_FILE" 2>/dev/null

    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:$pane" \
        "cat '$INPUT_JSON_FILE' | HOOK_CWD='$TEST_DIR' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

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

if jq -e '.hooks.PreToolUse[] | select(.matcher == "Bash") | .hooks[] | select(.command | contains("pm-bash-allowlist.py"))' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "PreToolUse hook configured for pm-bash-allowlist.py with Bash matcher"
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

# Create agents.yml: PM at window 0, developer at window 1
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

# Create identity.yml files
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

# Create tmux session: PM at window 0, developer at window 1, no-role at window 2
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
sleep 2

pass "Test directory and tmux session created"
echo ""

# ============================================================
# Phase 3: PM allowed commands
# ============================================================
echo "Phase 3: Testing PM allowed commands..."

# grep (read-only tool)
OUTPUT=$(run_hook_in_pane "0" 'grep -r "pattern" .')
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: grep"
else
    fail "PM should be allowed to run grep"
fi

# ls (read-only tool)
OUTPUT=$(run_hook_in_pane "0" "ls -la")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: ls"
else
    fail "PM should be allowed to run ls"
fi

# tmux (coordination)
OUTPUT=$(run_hook_in_pane "0" "tmux list-sessions")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: tmux"
else
    fail "PM should be allowed to run tmux"
fi

# uv run (yato scripts)
OUTPUT=$(run_hook_in_pane "0" "uv run python lib/tmux_utils.py send session:0 msg")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: uv run"
else
    fail "PM should be allowed to run uv"
fi

# git status (read-only git)
OUTPUT=$(run_hook_in_pane "0" "git status")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: git status"
else
    fail "PM should be allowed to run git status"
fi

# yato script via bash (full path containing /plugins/yato/)
OUTPUT=$(run_hook_in_pane "0" "bash $PROJECT_ROOT/bin/send-to-agent.sh dev msg")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: bash with yato script"
else
    fail "PM should be allowed to run bash with yato scripts"
fi

# yato script via bash (plugin cache path containing /claude-code-plugins/yato/)
CACHE_PATH="/home/user/.claude/plugins/cache/claude-code-plugins/yato/3.11.2/bin/create-team.sh"
OUTPUT=$(run_hook_in_pane "0" "bash $CACHE_PATH /project dev:developer:opus")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: bash with yato cache path script"
else
    fail "PM should be allowed to run bash with yato cache path scripts"
fi

# head (read-only tool)
OUTPUT=$(run_hook_in_pane "0" "head -20 file.txt")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: head"
else
    fail "PM should be allowed to run head"
fi

# pwd (info)
OUTPUT=$(run_hook_in_pane "0" "pwd")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: pwd"
else
    fail "PM should be allowed to run pwd"
fi

echo ""

# ============================================================
# Phase 4: PM blocked commands
# ============================================================
echo "Phase 4: Testing PM blocked commands..."

# echo (can write with redirects)
OUTPUT=$(run_hook_in_pane "0" 'echo "hello" > file.txt')
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: echo"
else
    fail "PM should be blocked from running echo"
fi

# sed -i (in-place edit)
OUTPUT=$(run_hook_in_pane "0" "sed -i 's/foo/bar/' file.txt")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: sed"
else
    fail "PM should be blocked from running sed"
fi

# python3 (can write programmatically)
OUTPUT=$(run_hook_in_pane "0" "python3 -c 'open(\"f\",\"w\").write(\"x\")'")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: python3"
else
    fail "PM should be blocked from running python3"
fi

# cp (file copy)
OUTPUT=$(run_hook_in_pane "0" "cp src.txt dst.txt")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: cp"
else
    fail "PM should be blocked from running cp"
fi

# rm (file deletion)
OUTPUT=$(run_hook_in_pane "0" "rm -rf /tmp/test")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: rm"
else
    fail "PM should be blocked from running rm"
fi

# cat (can write with redirects)
OUTPUT=$(run_hook_in_pane "0" "cat file.txt")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: cat"
else
    fail "PM should be blocked from running cat"
fi

# mkdir (file creation)
OUTPUT=$(run_hook_in_pane "0" "mkdir -p /tmp/test-dir")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: mkdir"
else
    fail "PM should be blocked from running mkdir"
fi

# touch (file creation)
OUTPUT=$(run_hook_in_pane "0" "touch newfile.txt")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: touch"
else
    fail "PM should be blocked from running touch"
fi

echo ""

# ============================================================
# Phase 5: Developer allowed (not PM - all commands pass)
# ============================================================
echo "Phase 5: Testing developer is allowed to run any command..."

# Developer can run echo (not restricted)
OUTPUT=$(run_hook_in_pane "1" 'echo "hello" > file.txt')
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Developer allowed: echo"
else
    fail "Developer should be allowed to run echo"
fi

# Developer can run sed
OUTPUT=$(run_hook_in_pane "1" "sed -i 's/foo/bar/' file.txt")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Developer allowed: sed"
else
    fail "Developer should be allowed to run sed"
fi

# Developer can run python3
OUTPUT=$(run_hook_in_pane "1" "python3 -c 'print(1)'")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "Developer allowed: python3"
else
    fail "Developer should be allowed to run python3"
fi

echo ""

# ============================================================
# Phase 6: User/orchestrator allowed (no role detected)
# ============================================================
echo "Phase 6: Testing user/orchestrator is allowed..."

# Window 2 has no matching identity.yml
OUTPUT=$(run_hook_in_pane "2" 'echo "hello" > file.txt')
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "User/orchestrator allowed: echo"
else
    fail "User/orchestrator should be allowed to run any command"
fi

OUTPUT=$(run_hook_in_pane "2" "python3 -c 'print(1)'")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "User/orchestrator allowed: python3"
else
    fail "User/orchestrator should be allowed to run any command"
fi

echo ""

# ============================================================
# Phase 7: Git subcommand validation
# ============================================================
echo "Phase 7: Testing git subcommand validation..."

# git status - allowed
OUTPUT=$(run_hook_in_pane "0" "git status")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: git status"
else
    fail "PM should be allowed to run git status"
fi

# git log - allowed
OUTPUT=$(run_hook_in_pane "0" "git log --oneline -10")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: git log"
else
    fail "PM should be allowed to run git log"
fi

# git diff - allowed
OUTPUT=$(run_hook_in_pane "0" "git diff HEAD~1")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: git diff"
else
    fail "PM should be allowed to run git diff"
fi

# git push - blocked
OUTPUT=$(run_hook_in_pane "0" "git push origin main")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: git push"
else
    fail "PM should be blocked from running git push"
fi

# git commit - blocked
OUTPUT=$(run_hook_in_pane "0" "git commit -m 'test'")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: git commit"
else
    fail "PM should be blocked from running git commit"
fi

# git checkout - blocked
OUTPUT=$(run_hook_in_pane "0" "git checkout main")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: git checkout"
else
    fail "PM should be blocked from running git checkout"
fi

# git add - blocked
OUTPUT=$(run_hook_in_pane "0" "git add .")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: git add"
else
    fail "PM should be blocked from running git add"
fi

echo ""

# ============================================================
# Phase 8: Chained commands (blocked if any segment fails)
# ============================================================
echo "Phase 8: Testing chained commands..."

# grep allowed but sed blocked → whole chain blocked
OUTPUT=$(run_hook_in_pane "0" "grep foo file.txt && sed -i 's/bar/baz/' file.txt")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: chained grep && sed"
else
    fail "PM should be blocked when chain contains sed"
fi

# All segments allowed
OUTPUT=$(run_hook_in_pane "0" "grep foo file.txt && ls -la && git status")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: chained grep && ls && git status"
else
    fail "PM should be allowed when all chain segments are allowed"
fi

# Piped: grep | sort (both allowed)
OUTPUT=$(run_hook_in_pane "0" "grep foo file.txt | sort | uniq")
if echo "$OUTPUT" | grep -q '"continue": true\|"continue":true'; then
    pass "PM allowed: piped grep | sort | uniq"
else
    fail "PM should be allowed when all pipe segments are allowed"
fi

# Piped with blocked: ls | python3 (python3 blocked)
OUTPUT=$(run_hook_in_pane "0" "ls | python3 -c 'import sys; sys.stdin.read()'")
if echo "$OUTPUT" | grep -q '"block"'; then
    pass "PM blocked: piped ls | python3"
else
    fail "PM should be blocked when pipe contains python3"
fi

echo ""

# ============================================================
# Phase 9: Invalid JSON stdin returns safe fallback
# ============================================================
echo "Phase 9: Testing invalid JSON stdin returns safe fallback..."

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" \
    "echo 'not valid json' | HOOK_CWD='$TEST_DIR' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

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
# Phase 10: Block message content
# ============================================================
echo "Phase 10: Testing block message content..."

BLOCK_OUTPUT=$(run_hook_in_pane "0" 'echo "test"')

if echo "$BLOCK_OUTPUT" | grep -qi "PM BASH COMMAND BLOCKED"; then
    pass "Block reason contains 'PM BASH COMMAND BLOCKED'"
else
    fail "Block reason should contain 'PM BASH COMMAND BLOCKED'"
fi

if echo "$BLOCK_OUTPUT" | grep -qi "delegate"; then
    pass "Block reason mentions delegation"
else
    fail "Block reason should mention delegation"
fi

if echo "$BLOCK_OUTPUT" | grep -qi "not in the PM allowlist"; then
    pass "Block reason mentions allowlist"
else
    fail "Block reason should mention allowlist"
fi

echo ""

# ============================================================
# Results
# ============================================================
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
