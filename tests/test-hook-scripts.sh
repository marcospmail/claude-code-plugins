#!/bin/bash
# Test hook scripts (capture-session-id.sh and block-task-tool.sh)
# Run: ./tests/test-hook-scripts.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/test-hooks-$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }

PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    echo ""
    echo "Cleaning up..."
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║          Testing Hook Scripts                                 ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

# Setup - create test project with workflow
echo "Setting up test environment in $TEST_DIR..."
mkdir -p "$TEST_DIR"
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test hooks" > /dev/null 2>&1

# Find the workflow directory
WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
WORKFLOW_NAME=$(basename "$WORKFLOW_DIR")

# Verify hooks were created
if [[ ! -f "$TEST_DIR/.claude/hooks/capture-session-id.sh" ]]; then
    echo -e "${RED}ERROR: capture-session-id.sh not created by init-workflow.sh${NC}"
    exit 1
fi

if [[ ! -f "$TEST_DIR/.claude/hooks/block-task-tool.sh" ]]; then
    echo -e "${RED}ERROR: block-task-tool.sh not created by init-workflow.sh${NC}"
    exit 1
fi

# ============================================================================
# Tests for capture-session-id.sh
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Tests for capture-session-id.sh"
echo "═══════════════════════════════════════════════════════════════"

# Test 1: PM pane writes to pm/identity.yml
echo ""
echo "=== Test 1: PM pane writes to pm/identity.yml ==="
cd "$TEST_DIR"
# Mock TMUX environment for PM
export TMUX="/tmp/tmux-test/default,12345,0"
export TMUX_PANE="%0"
# Create a function to mock tmux display-message
function tmux() {
    if [[ "$1" == "display-message" ]]; then
        echo "PM"
    fi
}
export -f tmux

SESSION_ID="test-pm-session-$(date +%s)"
echo '{"session_id": "'$SESSION_ID'"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && grep -q "session_id: $SESSION_ID" "$WORKFLOW_DIR/agents/pm/identity.yml" 2>/dev/null; then
    pass "PM session_id written to identity.yml"
else
    fail "PM session_id not written (exit code: $EXIT_CODE)"
fi

unset -f tmux

# Test 2: Developer pane writes to developer/identity.yml
echo ""
echo "=== Test 2: Developer pane writes to developer/identity.yml ==="
# Create developer agent directory
mkdir -p "$WORKFLOW_DIR/agents/developer"
cat > "$WORKFLOW_DIR/agents/developer/identity.yml" << 'EOF'
name: developer
role: developer
agent_id: pending
EOF

function tmux() {
    if [[ "$1" == "display-message" ]]; then
        echo "developer"
    fi
}
export -f tmux

DEV_SESSION_ID="test-dev-session-$(date +%s)"
echo '{"session_id": "'$DEV_SESSION_ID'"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && grep -q "session_id: $DEV_SESSION_ID" "$WORKFLOW_DIR/agents/developer/identity.yml" 2>/dev/null; then
    pass "Developer session_id written to identity.yml"
else
    fail "Developer session_id not written (exit code: $EXIT_CODE)"
fi

unset -f tmux

# Test 3: Empty session_id exits 0
echo ""
echo "=== Test 3: Empty session_id exits 0 ==="
echo '{"session_id": ""}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Empty session_id exits 0"
else
    fail "Empty session_id should exit 0 (got: $EXIT_CODE)"
fi

# Test 4: No workflow directory exits 0
echo ""
echo "=== Test 4: No workflow directory exits 0 ==="
NO_WORKFLOW_DIR="/tmp/test-no-workflow-$$"
mkdir -p "$NO_WORKFLOW_DIR/.claude/hooks"
cp "$TEST_DIR/.claude/hooks/capture-session-id.sh" "$NO_WORKFLOW_DIR/.claude/hooks/"
cd "$NO_WORKFLOW_DIR"

function tmux() { echo "PM"; }
export -f tmux

echo '{"session_id": "test-123"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "No workflow directory exits 0"
else
    fail "No workflow directory should exit 0 (got: $EXIT_CODE)"
fi
rm -rf "$NO_WORKFLOW_DIR"
unset -f tmux
cd "$TEST_DIR"

# Test 5: Check-ins pane is skipped
echo ""
echo "=== Test 5: Check-ins pane is skipped ==="
function tmux() { echo "Check-ins (refresh: 2s)"; }
export -f tmux

# Store current PM session_id
OLD_PM_SESSION=$(grep "session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml" | awk '{print $2}')
echo '{"session_id": "should-not-be-written"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?
NEW_PM_SESSION=$(grep "session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml" | awk '{print $2}')

if [[ $EXIT_CODE -eq 0 ]] && [[ "$OLD_PM_SESSION" == "$NEW_PM_SESSION" ]]; then
    pass "Check-ins pane skipped correctly"
else
    fail "Check-ins pane should be skipped"
fi
unset -f tmux

# Test 6: Empty pane title is skipped
echo ""
echo "=== Test 6: Empty pane title is skipped ==="
function tmux() { echo ""; }
export -f tmux

OLD_PM_SESSION=$(grep "session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml" | awk '{print $2}')
echo '{"session_id": "should-not-be-written-2"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?
NEW_PM_SESSION=$(grep "session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml" | awk '{print $2}')

if [[ $EXIT_CODE -eq 0 ]] && [[ "$OLD_PM_SESSION" == "$NEW_PM_SESSION" ]]; then
    pass "Empty pane title skipped correctly"
else
    fail "Empty pane title should be skipped"
fi
unset -f tmux

# Test 7: Missing identity file handled gracefully
echo ""
echo "=== Test 7: Missing identity file handled gracefully ==="
function tmux() { echo "nonexistent-agent"; }
export -f tmux

echo '{"session_id": "test-nonexistent"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?
if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Missing identity file handled gracefully"
else
    fail "Missing identity file should exit 0 (got: $EXIT_CODE)"
fi
unset -f tmux

# Test 8: Updates existing session_id
echo ""
echo "=== Test 8: Updates existing session_id (not duplicate) ==="
function tmux() { echo "PM"; }
export -f tmux

# Write first session_id
echo '{"session_id": "first-session"}' | bash .claude/hooks/capture-session-id.sh
# Write second session_id
echo '{"session_id": "second-session"}' | bash .claude/hooks/capture-session-id.sh

SESSION_COUNT=$(grep -c "session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml" 2>/dev/null || echo "0")
CURRENT_SESSION=$(grep "session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml" | tail -1 | awk '{print $2}')

if [[ "$SESSION_COUNT" == "1" ]] && [[ "$CURRENT_SESSION" == "second-session" ]]; then
    pass "Session_id updated, not duplicated"
else
    fail "Session_id duplicated or not updated (count: $SESSION_COUNT, value: $CURRENT_SESSION)"
fi
unset -f tmux

# Test 9: TMUX_PANE takes priority
echo ""
echo "=== Test 9: TMUX_PANE environment variable used ==="
# This test verifies the script uses TMUX_PANE with -t flag
# We can't fully test tmux -t behavior in isolation, so we verify the code path exists
if grep -q 'TMUX_PANE' "$TEST_DIR/.claude/hooks/capture-session-id.sh" && \
   grep -q '\-t.*TMUX_PANE' "$TEST_DIR/.claude/hooks/capture-session-id.sh"; then
    pass "TMUX_PANE with -t flag is used in script"
else
    fail "TMUX_PANE with -t flag not found in script"
fi

# Test 10: Agent name normalization
echo ""
echo "=== Test 10: Agent name normalization ==="
# Create agent with spaces/uppercase
mkdir -p "$WORKFLOW_DIR/agents/qa-engineer"
cat > "$WORKFLOW_DIR/agents/qa-engineer/identity.yml" << 'EOF'
name: QA Engineer
role: qa
agent_id: pending
EOF

function tmux() { echo "QA Engineer"; }
export -f tmux

QA_SESSION="qa-session-$(date +%s)"
echo '{"session_id": "'$QA_SESSION'"}' | bash .claude/hooks/capture-session-id.sh
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]] && grep -q "session_id: $QA_SESSION" "$WORKFLOW_DIR/agents/qa-engineer/identity.yml" 2>/dev/null; then
    pass "Agent name normalized (QA Engineer -> qa-engineer)"
else
    fail "Agent name normalization failed"
fi
unset -f tmux

# ============================================================================
# Tests for block-task-tool.sh
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Tests for block-task-tool.sh"
echo "═══════════════════════════════════════════════════════════════"

# First, set PM's session_id for testing
PM_SESSION_ID="pm-session-for-testing"
sed -i '' "s/^session_id:.*/session_id: $PM_SESSION_ID/" "$WORKFLOW_DIR/agents/pm/identity.yml" 2>/dev/null || \
sed -i "s/^session_id:.*/session_id: $PM_SESSION_ID/" "$WORKFLOW_DIR/agents/pm/identity.yml"

# Test 11: PM session_id matches - blocks
echo ""
echo "=== Test 11: PM session_id matches - blocks (exit 2) ==="
set +e  # Disable exit on error for this test
OUTPUT=$(echo '{"session_id": "'$PM_SESSION_ID'"}' | bash .claude/hooks/block-task-tool.sh 2>&1)
EXIT_CODE=$?
set -e  # Re-enable

if [[ $EXIT_CODE -eq 2 ]]; then
    pass "PM session blocked with exit code 2"
else
    fail "PM session should be blocked with exit 2 (got: $EXIT_CODE)"
fi

# Test 12: Developer session_id differs - allows
echo ""
echo "=== Test 12: Developer session_id differs - allows (exit 0) ==="
OUTPUT=$(echo '{"session_id": "different-session-id"}' | bash .claude/hooks/block-task-tool.sh 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Developer session allowed with exit code 0"
else
    fail "Developer session should be allowed with exit 0 (got: $EXIT_CODE)"
fi

# Test 13: Empty session_id in input - allows
echo ""
echo "=== Test 13: Empty session_id in input - allows (exit 0) ==="
OUTPUT=$(echo '{"session_id": ""}' | bash .claude/hooks/block-task-tool.sh 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Empty session_id allowed with exit code 0"
else
    fail "Empty session_id should be allowed (got: $EXIT_CODE)"
fi

# Test 14: No workflow directory - allows
echo ""
echo "=== Test 14: No workflow directory - allows (exit 0) ==="
NO_WORKFLOW_DIR2="/tmp/test-no-workflow2-$$"
mkdir -p "$NO_WORKFLOW_DIR2/.claude/hooks"
cp "$TEST_DIR/.claude/hooks/block-task-tool.sh" "$NO_WORKFLOW_DIR2/.claude/hooks/"
cd "$NO_WORKFLOW_DIR2"

OUTPUT=$(echo '{"session_id": "any-session"}' | bash .claude/hooks/block-task-tool.sh 2>&1)
EXIT_CODE=$?

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "No workflow directory allowed with exit code 0"
else
    fail "No workflow directory should be allowed (got: $EXIT_CODE)"
fi
rm -rf "$NO_WORKFLOW_DIR2"
cd "$TEST_DIR"

# Test 15: PM identity file missing - allows
echo ""
echo "=== Test 15: PM identity file missing - allows (exit 0) ==="
mv "$WORKFLOW_DIR/agents/pm/identity.yml" "$WORKFLOW_DIR/agents/pm/identity.yml.bak"

OUTPUT=$(echo '{"session_id": "any-session"}' | bash .claude/hooks/block-task-tool.sh 2>&1)
EXIT_CODE=$?

mv "$WORKFLOW_DIR/agents/pm/identity.yml.bak" "$WORKFLOW_DIR/agents/pm/identity.yml"

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "Missing PM identity file allowed with exit code 0"
else
    fail "Missing PM identity file should be allowed (got: $EXIT_CODE)"
fi

# Test 16: PM has no session_id field - allows
echo ""
echo "=== Test 16: PM has no session_id field - allows (exit 0) ==="
# Backup and remove session_id
cp "$WORKFLOW_DIR/agents/pm/identity.yml" "$WORKFLOW_DIR/agents/pm/identity.yml.bak"
grep -v "^session_id:" "$WORKFLOW_DIR/agents/pm/identity.yml.bak" > "$WORKFLOW_DIR/agents/pm/identity.yml"

OUTPUT=$(echo '{"session_id": "any-session"}' | bash .claude/hooks/block-task-tool.sh 2>&1)
EXIT_CODE=$?

mv "$WORKFLOW_DIR/agents/pm/identity.yml.bak" "$WORKFLOW_DIR/agents/pm/identity.yml"

if [[ $EXIT_CODE -eq 0 ]]; then
    pass "PM without session_id allowed with exit code 0"
else
    fail "PM without session_id should be allowed (got: $EXIT_CODE)"
fi

# Test 17: Correct error message on block
echo ""
echo "=== Test 17: Correct error message on block ==="
set +e  # Disable exit on error for this test
OUTPUT=$(echo '{"session_id": "'$PM_SESSION_ID'"}' | bash .claude/hooks/block-task-tool.sh 2>&1)
set -e  # Re-enable

if echo "$OUTPUT" | grep -q "BLOCKED: PM cannot use Task tool\|Task tool is blocked for PM"; then
    pass "Error message contains expected text"
else
    fail "Error message incorrect: $OUTPUT"
fi

# ============================================================================
# Tests for init-workflow.sh hook creation
# ============================================================================

echo ""
echo "═══════════════════════════════════════════════════════════════"
echo "  Tests for init-workflow.sh hook creation"
echo "═══════════════════════════════════════════════════════════════"

# Test 18: Creates .claude/hooks directory
echo ""
echo "=== Test 18: Creates .claude/hooks directory ==="
if [[ -d "$TEST_DIR/.claude/hooks" ]]; then
    pass ".claude/hooks directory created"
else
    fail ".claude/hooks directory not created"
fi

# Test 19: settings.json has correct structure
echo ""
echo "=== Test 19: settings.json has correct structure ==="
if [[ -f "$TEST_DIR/.claude/settings.json" ]]; then
    # Check for SessionStart hook
    if grep -q '"SessionStart"' "$TEST_DIR/.claude/settings.json" && \
       grep -q '"PreToolUse"' "$TEST_DIR/.claude/settings.json" && \
       grep -q '"matcher": "Task"' "$TEST_DIR/.claude/settings.json"; then
        pass "settings.json has correct hook structure"
    else
        fail "settings.json missing required hooks"
    fi
else
    fail "settings.json not created"
fi

# Test 20: Hook scripts are executable
echo ""
echo "=== Test 20: Hook scripts are executable ==="
CAPTURE_EXEC=false
BLOCK_EXEC=false

if [[ -x "$TEST_DIR/.claude/hooks/capture-session-id.sh" ]]; then
    CAPTURE_EXEC=true
fi

if [[ -x "$TEST_DIR/.claude/hooks/block-task-tool.sh" ]]; then
    BLOCK_EXEC=true
fi

if [[ "$CAPTURE_EXEC" == "true" ]] && [[ "$BLOCK_EXEC" == "true" ]]; then
    pass "Both hook scripts are executable"
else
    fail "Hook scripts not executable (capture: $CAPTURE_EXEC, block: $BLOCK_EXEC)"
fi

# ============================================================================
# Summary
# ============================================================================

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $PASSED"
echo -e "  ${RED}Failed${NC}:  $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
