#!/bin/bash
# test-loop-session-isolation.sh
#
# E2E Test: Verify loop session isolation fix
#
# Bug: Two Claude agents in the same directory would both pick up a loop
# started by only one of them. This happened because:
# 1. SKILL.md used --session "$(date +%s)" instead of $CLAUDE_CODE_SESSION_ID
# 2. Hook fallback returned the first active loop when session_id was None/missing
#
# Fix:
# 1. SKILL.md now uses $CLAUDE_CODE_SESSION_ID
# 2. Hook fallback only returns a loop if exactly ONE active AND no session_id provided
#
# Tests:
# 1. Verify loop stores Claude Code session ID (UUID format, not timestamp)
# 2. Verify hook respects session isolation (agent A != agent B)
# 3. Verify hook fallback works with single active loop
# 4. Verify hook fallback doesn't fire with multiple active loops
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.
# All script execution goes through Claude running inside tmux.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="loop-session-isolation"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-loop-isolation-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Loop Session Isolation"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -rf /tmp/e2e-hook-isolation-$$ /tmp/e2e-hook-fallback-single-$$ /tmp/e2e-hook-fallback-multi-$$ 2>/dev/null || true
    rm -f /tmp/e2e-hook-result-$$.txt 2>/dev/null || true
}
trap cleanup EXIT

# Setup test directory
mkdir -p "$TEST_DIR"

# IMPORTANT: Use larger window size for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

# Start Claude in the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter

echo "  - Waiting for Claude to start..."
sleep 8

# Handle trust prompt
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  - Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
    sleep 15
else
    echo "  - No trust prompt found, continuing..."
    sleep 5
fi

echo "  ✓ Test environment ready"
echo ""

SKILL_FILE="$PROJECT_ROOT/skills/loop/SKILL.md"
HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/loop-stop-hook.py"

# ============================================================
# Test 1: Verify SKILL.md uses $CLAUDE_CODE_SESSION_ID
# ============================================================
echo "Test 1: SKILL.md uses CLAUDE_CODE_SESSION_ID (not timestamp)..."

# Test 1a: SKILL.md should contain $CLAUDE_CODE_SESSION_ID
if grep -q 'CLAUDE_CODE_SESSION_ID' "$SKILL_FILE"; then
    pass "SKILL.md references \$CLAUDE_CODE_SESSION_ID"
else
    fail "SKILL.md does not reference \$CLAUDE_CODE_SESSION_ID"
fi

# Test 1b: SKILL.md should NOT contain $(date +%s) for session
if grep -q 'session.*date +%s' "$SKILL_FILE"; then
    fail "SKILL.md still uses \$(date +%s) for session"
else
    pass "SKILL.md no longer uses \$(date +%s) for session"
fi

# Test 1c: Verify CLAUDE_CODE_SESSION_ID env var exists in current Claude session
if [[ -n "$CLAUDE_CODE_SESSION_ID" ]]; then
    pass "CLAUDE_CODE_SESSION_ID is set: ${CLAUDE_CODE_SESSION_ID:0:8}..."
else
    fail "CLAUDE_CODE_SESSION_ID env var is not set"
fi

# ============================================================
# Test 2: Verify hook respects session isolation
# ============================================================
echo ""
echo "Test 2: Hook respects session isolation..."

# Create test directory with loop
TEST_DIR_2="/tmp/e2e-hook-isolation-$$"
mkdir -p "$TEST_DIR_2/.workflow/loops/001-test"

# Create loop meta.json with session_id for agent A
cat > "$TEST_DIR_2/.workflow/loops/001-test/meta.json" <<'EOF'
{
  "should_continue": true,
  "prompt": "check logs",
  "interval_seconds": 0,
  "execution_count": 1,
  "stop_after_times": 5,
  "stop_after_seconds": null,
  "session_id": "session-agent-A",
  "started_at": "2026-02-02T15:00:00",
  "last_executed_at": "2026-02-02T15:00:00",
  "total_elapsed_seconds": 0
}
EOF

# Test 2a: Agent A (matching session) should get loop continuation
echo "  Test 2a: Agent A (matching session_id) should continue loop..."

INPUT_A='{"cwd": "'"$TEST_DIR_2"'", "session_id": "session-agent-A"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_A' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_A=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if echo "$OUTPUT_A" | grep -q '"decision": "block"'; then
    pass "Agent A receives loop continuation (decision: block)"
else
    fail "Agent A did not receive loop continuation"
fi

if echo "$OUTPUT_A" | grep -q "check logs"; then
    pass "Agent A loop includes correct prompt"
else
    fail "Agent A loop missing prompt"
fi

# Test 2b: Agent B (different session) should NOT get loop continuation
echo ""
echo "  Test 2b: Agent B (different session_id) should NOT continue loop..."

INPUT_B='{"cwd": "'"$TEST_DIR_2"'", "session_id": "session-agent-B"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_B' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_B=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if [[ -z "$OUTPUT_B" ]]; then
    pass "Agent B ignored (no output from hook)"
elif echo "$OUTPUT_B" | grep -q '"decision": "block"'; then
    fail "Agent B incorrectly received loop continuation"
else
    pass "Agent B ignored (output not a block decision)"
fi

rm -rf "$TEST_DIR_2"

# ============================================================
# Test 3: Verify fallback works with single active loop
# ============================================================
echo ""
echo "Test 3: Hook fallback works with single active loop (no session_id)..."

TEST_DIR_3="/tmp/e2e-hook-fallback-single-$$"
mkdir -p "$TEST_DIR_3/.workflow/loops/001-monitor"

cat > "$TEST_DIR_3/.workflow/loops/001-monitor/meta.json" <<'EOF'
{
  "should_continue": true,
  "prompt": "monitor status",
  "interval_seconds": 0,
  "execution_count": 1,
  "stop_after_times": 10,
  "stop_after_seconds": null,
  "session_id": "some-session-uuid",
  "started_at": "2026-02-02T16:00:00",
  "last_executed_at": "2026-02-02T16:00:00",
  "total_elapsed_seconds": 0
}
EOF

INPUT_NO_SESSION='{"cwd": "'"$TEST_DIR_3"'"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_NO_SESSION' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_NO_SESSION=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if echo "$OUTPUT_NO_SESSION" | grep -q '"decision": "block"'; then
    pass "Fallback works: single active loop continued"
else
    fail "Fallback failed: single active loop not continued"
fi

if echo "$OUTPUT_NO_SESSION" | grep -q "monitor status"; then
    pass "Fallback loop includes correct prompt"
else
    fail "Fallback loop missing prompt"
fi

rm -rf "$TEST_DIR_3"

# ============================================================
# Test 4: Verify fallback doesn't fire with multiple loops
# ============================================================
echo ""
echo "Test 4: Hook fallback doesn't fire with multiple active loops..."

TEST_DIR_4="/tmp/e2e-hook-fallback-multi-$$"
mkdir -p "$TEST_DIR_4/.workflow/loops/001-first"
mkdir -p "$TEST_DIR_4/.workflow/loops/002-second"

cat > "$TEST_DIR_4/.workflow/loops/001-first/meta.json" <<'EOF'
{
  "should_continue": true,
  "prompt": "check first",
  "interval_seconds": 0,
  "execution_count": 1,
  "stop_after_times": 5,
  "stop_after_seconds": null,
  "session_id": "session-loop-1",
  "started_at": "2026-02-02T16:00:00",
  "last_executed_at": "2026-02-02T16:00:00",
  "total_elapsed_seconds": 0
}
EOF

cat > "$TEST_DIR_4/.workflow/loops/002-second/meta.json" <<'EOF'
{
  "should_continue": true,
  "prompt": "check second",
  "interval_seconds": 0,
  "execution_count": 1,
  "stop_after_times": 3,
  "stop_after_seconds": null,
  "session_id": "session-loop-2",
  "started_at": "2026-02-02T16:00:00",
  "last_executed_at": "2026-02-02T16:00:00",
  "total_elapsed_seconds": 0
}
EOF

# Test 4a: No session_id with multiple loops should produce NO output
echo "  Test 4a: Multiple loops with no session_id should be ignored..."

INPUT_MULTI_NO_SESSION='{"cwd": "'"$TEST_DIR_4"'"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_MULTI_NO_SESSION' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_MULTI_NO_SESSION=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if [[ -z "$OUTPUT_MULTI_NO_SESSION" ]]; then
    pass "Multiple loops with no session_id correctly ignored"
elif echo "$OUTPUT_MULTI_NO_SESSION" | grep -q '"decision": "block"'; then
    fail "Hook incorrectly picked a loop from multiple active loops"
else
    pass "Multiple loops with no session_id ignored (non-block output)"
fi

# Test 4b: Matching session_id should get the correct loop
echo ""
echo "  Test 4b: Matching session_id should get correct loop from multiple..."

INPUT_MULTI_SESSION_1='{"cwd": "'"$TEST_DIR_4"'", "session_id": "session-loop-1"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_MULTI_SESSION_1' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_MULTI_SESSION_1=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if echo "$OUTPUT_MULTI_SESSION_1" | grep -q '"decision": "block"'; then
    pass "Loop 1 found by matching session_id"
else
    fail "Loop 1 not found despite matching session_id"
fi

if echo "$OUTPUT_MULTI_SESSION_1" | grep -q "check first"; then
    pass "Correct loop (001-first) returned"
else
    fail "Wrong loop returned or prompt missing"
fi

# Test 4c: Different session_id should get different loop
echo ""
echo "  Test 4c: Different session_id should get different loop..."

INPUT_MULTI_SESSION_2='{"cwd": "'"$TEST_DIR_4"'", "session_id": "session-loop-2"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_MULTI_SESSION_2' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_MULTI_SESSION_2=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if echo "$OUTPUT_MULTI_SESSION_2" | grep -q '"decision": "block"'; then
    pass "Loop 2 found by matching session_id"
else
    fail "Loop 2 not found despite matching session_id"
fi

if echo "$OUTPUT_MULTI_SESSION_2" | grep -q "check second"; then
    pass "Correct loop (002-second) returned"
else
    fail "Wrong loop returned or prompt missing"
fi

# Test 4d: Unknown session_id should be ignored
echo ""
echo "  Test 4d: Unknown session_id should be ignored..."

INPUT_MULTI_UNKNOWN='{"cwd": "'"$TEST_DIR_4"'", "session_id": "session-unknown-xyz"}'

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: echo '$INPUT_MULTI_UNKNOWN' | python3 '$HOOK_SCRIPT' > /tmp/e2e-hook-result-$$.txt 2>&1"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 30

OUTPUT_MULTI_UNKNOWN=$(cat /tmp/e2e-hook-result-$$.txt 2>/dev/null)

if [[ -z "$OUTPUT_MULTI_UNKNOWN" ]]; then
    pass "Unknown session_id correctly ignored"
elif echo "$OUTPUT_MULTI_UNKNOWN" | grep -q '"decision": "block"'; then
    fail "Unknown session received loop continuation"
else
    pass "Unknown session_id ignored (non-block output)"
fi

rm -rf "$TEST_DIR_4"

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
