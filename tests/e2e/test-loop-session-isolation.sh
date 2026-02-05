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

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="loop-session-isolation"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-loop-isolation-$$"

echo "======================================================================"
echo "  E2E Test: Loop Session Isolation"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Test 1: Verify SKILL.md uses $CLAUDE_CODE_SESSION_ID
# ============================================================
echo ""
echo "Test 1: SKILL.md uses CLAUDE_CODE_SESSION_ID (not timestamp)..."
echo ""

# Setup test directory (needed by later tests)
mkdir -p "$TEST_DIR"

SKILL_FILE="$PROJECT_ROOT/skills/loop/SKILL.md"

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
echo ""

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

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/loop-stop-hook.py"

# Test 2a: Agent A (matching session) should get loop continuation
echo "Test 2a: Agent A (matching session_id) should continue loop..."
INPUT_A=$(cat <<EOF
{
  "cwd": "$TEST_DIR_2",
  "session_id": "session-agent-A"
}
EOF
)

OUTPUT_A=$(echo "$INPUT_A" | python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT_A" | grep -q '"decision": "block"'; then
    pass "Agent A receives loop continuation (decision: block)"
else
    fail "Agent A did not receive loop continuation"
    echo "  Output: $OUTPUT_A"
fi

if echo "$OUTPUT_A" | grep -q "check logs"; then
    pass "Agent A loop includes correct prompt"
else
    fail "Agent A loop missing prompt"
fi

# Test 2b: Agent B (different session) should NOT get loop continuation
echo ""
echo "Test 2b: Agent B (different session_id) should NOT continue loop..."
INPUT_B=$(cat <<EOF
{
  "cwd": "$TEST_DIR_2",
  "session_id": "session-agent-B"
}
EOF
)

OUTPUT_B=$(echo "$INPUT_B" | python3 "$HOOK_SCRIPT" 2>&1)

if [[ -z "$OUTPUT_B" ]]; then
    pass "Agent B ignored (no output from hook)"
elif echo "$OUTPUT_B" | grep -q '"decision": "block"'; then
    fail "Agent B incorrectly received loop continuation"
    echo "  Output: $OUTPUT_B"
else
    pass "Agent B ignored (output not a block decision)"
fi

# Cleanup
rm -rf "$TEST_DIR_2"

# ============================================================
# Test 3: Verify fallback works with single active loop
# ============================================================
echo ""
echo "Test 3: Hook fallback works with single active loop (no session_id)..."
echo ""

# Create test directory with single loop (no session_id in hook input)
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

# Hook input WITHOUT session_id (simulates older Claude Code or missing context)
INPUT_NO_SESSION=$(cat <<EOF
{
  "cwd": "$TEST_DIR_3"
}
EOF
)

OUTPUT_NO_SESSION=$(echo "$INPUT_NO_SESSION" | python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT_NO_SESSION" | grep -q '"decision": "block"'; then
    pass "Fallback works: single active loop continued"
else
    fail "Fallback failed: single active loop not continued"
    echo "  Output: $OUTPUT_NO_SESSION"
fi

if echo "$OUTPUT_NO_SESSION" | grep -q "monitor status"; then
    pass "Fallback loop includes correct prompt"
else
    fail "Fallback loop missing prompt"
fi

# Cleanup
rm -rf "$TEST_DIR_3"

# ============================================================
# Test 4: Verify fallback doesn't fire with multiple loops
# ============================================================
echo ""
echo "Test 4: Hook fallback doesn't fire with multiple active loops..."
echo ""

# Create test directory with TWO active loops
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
echo "Test 4a: Multiple loops with no session_id should be ignored..."
INPUT_MULTI_NO_SESSION=$(cat <<EOF
{
  "cwd": "$TEST_DIR_4"
}
EOF
)

OUTPUT_MULTI_NO_SESSION=$(echo "$INPUT_MULTI_NO_SESSION" | python3 "$HOOK_SCRIPT" 2>&1)

if [[ -z "$OUTPUT_MULTI_NO_SESSION" ]]; then
    pass "Multiple loops with no session_id correctly ignored"
elif echo "$OUTPUT_MULTI_NO_SESSION" | grep -q '"decision": "block"'; then
    fail "Hook incorrectly picked a loop from multiple active loops"
    echo "  Output: $OUTPUT_MULTI_NO_SESSION"
else
    pass "Multiple loops with no session_id ignored (non-block output)"
fi

# Test 4b: Matching session_id should get the correct loop
echo ""
echo "Test 4b: Matching session_id should get correct loop from multiple..."
INPUT_MULTI_SESSION_1=$(cat <<EOF
{
  "cwd": "$TEST_DIR_4",
  "session_id": "session-loop-1"
}
EOF
)

OUTPUT_MULTI_SESSION_1=$(echo "$INPUT_MULTI_SESSION_1" | python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT_MULTI_SESSION_1" | grep -q '"decision": "block"'; then
    pass "Loop 1 found by matching session_id"
else
    fail "Loop 1 not found despite matching session_id"
    echo "  Output: $OUTPUT_MULTI_SESSION_1"
fi

if echo "$OUTPUT_MULTI_SESSION_1" | grep -q "check first"; then
    pass "Correct loop (001-first) returned"
else
    fail "Wrong loop returned or prompt missing"
    echo "  Output: $OUTPUT_MULTI_SESSION_1"
fi

# Test 4c: Different session_id should get different loop
echo ""
echo "Test 4c: Different session_id should get different loop..."
INPUT_MULTI_SESSION_2=$(cat <<EOF
{
  "cwd": "$TEST_DIR_4",
  "session_id": "session-loop-2"
}
EOF
)

OUTPUT_MULTI_SESSION_2=$(echo "$INPUT_MULTI_SESSION_2" | python3 "$HOOK_SCRIPT" 2>&1)

if echo "$OUTPUT_MULTI_SESSION_2" | grep -q '"decision": "block"'; then
    pass "Loop 2 found by matching session_id"
else
    fail "Loop 2 not found despite matching session_id"
    echo "  Output: $OUTPUT_MULTI_SESSION_2"
fi

if echo "$OUTPUT_MULTI_SESSION_2" | grep -q "check second"; then
    pass "Correct loop (002-second) returned"
else
    fail "Wrong loop returned or prompt missing"
    echo "  Output: $OUTPUT_MULTI_SESSION_2"
fi

# Test 4d: Unknown session_id should be ignored
echo ""
echo "Test 4d: Unknown session_id should be ignored..."
INPUT_MULTI_UNKNOWN=$(cat <<EOF
{
  "cwd": "$TEST_DIR_4",
  "session_id": "session-unknown-xyz"
}
EOF
)

OUTPUT_MULTI_UNKNOWN=$(echo "$INPUT_MULTI_UNKNOWN" | python3 "$HOOK_SCRIPT" 2>&1)

if [[ -z "$OUTPUT_MULTI_UNKNOWN" ]]; then
    pass "Unknown session_id correctly ignored"
elif echo "$OUTPUT_MULTI_UNKNOWN" | grep -q '"decision": "block"'; then
    fail "Unknown session received loop continuation"
    echo "  Output: $OUTPUT_MULTI_UNKNOWN"
else
    pass "Unknown session_id ignored (non-block output)"
fi

# Cleanup
rm -rf "$TEST_DIR_4"

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
