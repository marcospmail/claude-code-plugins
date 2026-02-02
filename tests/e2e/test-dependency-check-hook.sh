#!/bin/bash
# test-dependency-check-hook.sh
#
# E2E Test: Dependency Check Hook (tmux detection)
#
# This test verifies:
# 1. check-deps.sh outputs nothing when tmux is installed
# 2. check-deps.sh outputs correct JSON when tmux is missing
# 3. JSON structure is valid with correct fields
# 4. AskUserQuestion instructions are present
# 5. tmux website URL is correct
# 6. hooks.json configuration is valid
# 7. Script is executable
# 8. CLAUDE_PLUGIN_ROOT path is used correctly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="dependency-check-hook"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Dependency Check Hook                             ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Track test results
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

CHECK_DEPS_SCRIPT="$PROJECT_ROOT/hooks/scripts/check-deps.sh"
HOOKS_JSON="$PROJECT_ROOT/hooks/hooks.json"

# ============================================================
# PHASE 1: File existence and permissions
# ============================================================
echo "Phase 1: Checking file existence and permissions..."

# Test 1: check-deps.sh exists
if [[ -f "$CHECK_DEPS_SCRIPT" ]]; then
    pass "check-deps.sh exists"
else
    fail "check-deps.sh not found at $CHECK_DEPS_SCRIPT"
    exit 1
fi

# Test 2: check-deps.sh is executable
if [[ -x "$CHECK_DEPS_SCRIPT" ]]; then
    pass "check-deps.sh is executable"
else
    fail "check-deps.sh is not executable"
fi

# Test 3: hooks.json exists
if [[ -f "$HOOKS_JSON" ]]; then
    pass "hooks.json exists"
else
    fail "hooks.json not found at $HOOKS_JSON"
    exit 1
fi

echo ""

# ============================================================
# PHASE 2: hooks.json configuration validity
# ============================================================
echo "Phase 2: Checking hooks.json configuration..."

# Test 4: hooks.json is valid JSON
if jq empty "$HOOKS_JSON" 2>/dev/null; then
    pass "hooks.json is valid JSON"
else
    fail "hooks.json is not valid JSON"
fi

# Test 5: hooks.json has SessionStart hook
if jq -e '.hooks.SessionStart' "$HOOKS_JSON" >/dev/null 2>&1; then
    pass "hooks.json has SessionStart hook"
else
    fail "hooks.json missing SessionStart hook"
fi

# Test 6: SessionStart has startup matcher
if jq -e '.hooks.SessionStart[0].matcher == "startup"' "$HOOKS_JSON" 2>/dev/null | grep -q true; then
    pass "SessionStart has 'startup' matcher"
else
    fail "SessionStart missing 'startup' matcher"
fi

# Test 7: Hook uses CLAUDE_PLUGIN_ROOT variable
if jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null | grep -q 'CLAUDE_PLUGIN_ROOT'; then
    pass "Hook command uses CLAUDE_PLUGIN_ROOT variable"
else
    fail "Hook command doesn't use CLAUDE_PLUGIN_ROOT variable"
fi

# Test 8: Hook command path points to check-deps.sh
if jq -r '.hooks.SessionStart[0].hooks[0].command' "$HOOKS_JSON" 2>/dev/null | grep -q 'check-deps.sh'; then
    pass "Hook command references check-deps.sh"
else
    fail "Hook command doesn't reference check-deps.sh"
fi

# Test 9: Hook type is command
if jq -e '.hooks.SessionStart[0].hooks[0].type == "command"' "$HOOKS_JSON" 2>/dev/null | grep -q true; then
    pass "Hook type is 'command'"
else
    fail "Hook type is not 'command'"
fi

echo ""

# ============================================================
# PHASE 3: Script behavior when tmux IS installed
# ============================================================
echo "Phase 3: Testing script when tmux is installed..."

# Test 10: Script outputs nothing when tmux is installed
OUTPUT=$(bash "$CHECK_DEPS_SCRIPT" 2>&1)
if [[ -z "$OUTPUT" ]]; then
    pass "Script outputs nothing when tmux is installed"
else
    fail "Script should output nothing when tmux is installed, got: $OUTPUT"
fi

# Test 11: Script exits 0 when tmux is installed
bash "$CHECK_DEPS_SCRIPT" >/dev/null 2>&1
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Script exits 0 when tmux is installed"
else
    fail "Script should exit 0 when tmux is installed, got exit code: $EXIT_CODE"
fi

echo ""

# ============================================================
# PHASE 4: Script behavior when tmux is MISSING
# ============================================================
echo "Phase 4: Testing script when tmux is missing..."

# Simulate tmux not being installed by modifying PATH
MISSING_OUTPUT=$(PATH=/usr/bin:/bin bash "$CHECK_DEPS_SCRIPT" 2>&1)

# Test 12: Script outputs JSON when tmux is missing
if echo "$MISSING_OUTPUT" | jq empty 2>/dev/null; then
    pass "Script outputs valid JSON when tmux is missing"
else
    fail "Script output is not valid JSON when tmux is missing"
fi

# Test 13: JSON has hookSpecificOutput field
if echo "$MISSING_OUTPUT" | jq -e '.hookSpecificOutput' >/dev/null 2>&1; then
    pass "JSON has hookSpecificOutput field"
else
    fail "JSON missing hookSpecificOutput field"
fi

# Test 14: hookSpecificOutput has hookEventName
if echo "$MISSING_OUTPUT" | jq -e '.hookSpecificOutput.hookEventName == "SessionStart"' 2>/dev/null | grep -q true; then
    pass "hookEventName is 'SessionStart'"
else
    fail "hookEventName is not 'SessionStart'"
fi

# Test 15: hookSpecificOutput has additionalContext
if echo "$MISSING_OUTPUT" | jq -e '.hookSpecificOutput.additionalContext' >/dev/null 2>&1; then
    pass "JSON has additionalContext field"
else
    fail "JSON missing additionalContext field"
fi

echo ""

# ============================================================
# PHASE 5: additionalContext content validation
# ============================================================
echo "Phase 5: Checking additionalContext content..."

CONTEXT=$(echo "$MISSING_OUTPUT" | jq -r '.hookSpecificOutput.additionalContext' 2>/dev/null)

# Test 16: Context mentions tmux is not installed
if echo "$CONTEXT" | grep -qi "tmux.*not installed\|not installed.*tmux"; then
    pass "Context mentions tmux is not installed"
else
    fail "Context doesn't mention tmux is not installed"
fi

# Test 17: Context mentions AskUserQuestion
if echo "$CONTEXT" | grep -q "AskUserQuestion"; then
    pass "Context mentions AskUserQuestion"
else
    fail "Context doesn't mention AskUserQuestion"
fi

# Test 18: Context has Yes option for opening website
if echo "$CONTEXT" | grep -qi "Yes.*open.*website\|open.*website.*Yes"; then
    pass "Context has Yes option for opening website"
else
    fail "Context missing Yes option for opening website"
fi

# Test 19: Context has No option
if echo "$CONTEXT" | grep -qi "No thanks\|No,"; then
    pass "Context has No option"
else
    fail "Context missing No option"
fi

# Test 20: Context contains tmux wiki URL
if echo "$CONTEXT" | grep -q "https://github.com/tmux/tmux/wiki"; then
    pass "Context contains tmux wiki URL"
else
    fail "Context missing tmux wiki URL"
fi

# Test 21: Context mentions open command for macOS
if echo "$CONTEXT" | grep -q "open https://"; then
    pass "Context mentions 'open' command for macOS"
else
    fail "Context missing 'open' command for macOS"
fi

# Test 22: Context mentions Yato skills won't work
if echo "$CONTEXT" | grep -qi "Yato.*will not work\|won't work\|skills.*not work"; then
    pass "Context mentions Yato skills won't work without tmux"
else
    fail "Context doesn't mention Yato skills won't work"
fi

echo ""

# ============================================================
# RESULTS
# ============================================================
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                              ║"
    EXIT_CODE=0
else
    printf "║  ❌ SOME TESTS FAILED (%d failed, %d passed)                    ║\n" $TESTS_FAILED $TESTS_PASSED
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
