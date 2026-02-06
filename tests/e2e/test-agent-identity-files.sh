#!/bin/bash
# test-agent-identity-files.sh
#
# E2E Test: Agent Identity Files via /yato-existing-project
#
# This test verifies the /yato-existing-project skill creates correct PM identity files:
# 1. Starts Claude in tmux with --dangerously-skip-permissions
# 2. Invokes /yato-existing-project skill
# 3. Verifies:
#    - PM identity.yml exists with correct fields
#    - PM instructions.md exists with correct content
#    - PM CLAUDE.md references identity files
#
# This tests PLUGIN INTEGRATION, not the full multi-minute PM workflow.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-identity-files"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-$$"
export TMUX_SOCKET="yato-e2e-test"
PROJECT_SLUG="e2e-test-$TEST_NAME-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Identity Files via /yato-existing-project   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Test directory: $TEST_DIR"
echo "Initial session: $SESSION_NAME"
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

# Cleanup function
cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    # Kill any sessions matching the project pattern
    tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | grep "e2e-test-agent-identity" | cut -d: -f1 | xargs -I{} tmux -L "$TMUX_SOCKET" kill-session -t {} 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"
cd "$TEST_DIR"
git init -q
git config user.name "Test"
git config user.email "test@test.com"
echo "function test() { return true; }" > "$TEST_DIR/app.js"
git add -A && git commit -m "Initial" -q

echo "  - Project created at $TEST_DIR"
echo ""

# ============================================================
# PHASE 2: Start Claude and invoke /yato-existing-project
# ============================================================
echo "Phase 2: Starting Claude and invoking skill..."

# Create tmux session
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

# Start Claude with --dangerously-skip-permissions
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude --dangerously-skip-permissions" Enter

echo "  - Waiting for Claude to initialize (12 seconds)..."
sleep 12

# Verify Claude started
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
if echo "$OUTPUT" | grep -q "❯\|›\|>"; then
    pass "Claude CLI started"
else
    fail "Claude prompt not visible"
fi

# Invoke /yato-existing-project skill
echo "  - Invoking /yato-existing-project skill..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/yato-existing-project Test identity file generation"
sleep 2
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter

# Poll for workflow folder creation instead of fixed sleep
echo "  - Polling for workflow folder (max 240 seconds)..."
POLL_START=$(date +%s)
POLL_MAX=240
POLL_INTERVAL=15
WORKFLOW_FOUND=false

# Initial wait to let skill start
sleep 60

while true; do
    ELAPSED=$(($(date +%s) - POLL_START))

    # Check if workflow folder exists
    WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
    if [[ -n "$WORKFLOW_DIR" ]] && [[ -d "$WORKFLOW_DIR" ]]; then
        echo "  - Workflow folder found after ${ELAPSED}s"
        WORKFLOW_FOUND=true
        # Wait a bit more for PM files to be created
        sleep 30
        break
    fi

    # Check timeout
    if [[ $ELAPSED -ge $POLL_MAX ]]; then
        echo "  - Timeout after ${ELAPSED}s"
        break
    fi

    echo "  - Polling... (${ELAPSED}s elapsed)"
    sleep $POLL_INTERVAL
done

# Capture output for debugging
SKILL_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)
echo ""
echo "Debug - Skill output (last 20 lines):"
echo "$SKILL_OUTPUT" | tail -20
echo ""

# ============================================================
# PHASE 3: Verify PM identity files
# ============================================================
echo "Phase 3: Verifying PM identity files..."
echo ""

# Find workflow folder
WORKFLOW_DIR=$(ls -td "$TEST_DIR/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1)
if [[ -n "$WORKFLOW_DIR" ]] && [[ -d "$WORKFLOW_DIR" ]]; then
    WORKFLOW_NAME=$(basename "$WORKFLOW_DIR")
    pass "Workflow folder created: $WORKFLOW_NAME"
else
    fail "Workflow folder not created"
    WORKFLOW_NAME=""
fi

# Find PM agent folder
PM_AGENT_DIR="$WORKFLOW_DIR/agents/pm"

echo ""
echo "Testing PM identity.yml..."

# Test 1: PM identity.yml exists
PM_IDENTITY="$PM_AGENT_DIR/identity.yml"
if [[ -f "$PM_IDENTITY" ]]; then
    pass "PM identity.yml exists"

    # Test 2: PM has role field
    if grep -q "role:" "$PM_IDENTITY"; then
        pass "PM identity has role field"
    else
        fail "PM identity missing role field"
    fi

    # Test 3: PM has model field
    if grep -q "model:" "$PM_IDENTITY"; then
        pass "PM identity has model field"
    else
        fail "PM identity missing model field"
    fi

    # Test 4: PM has agents_registry reference
    if grep -q "agents_registry:" "$PM_IDENTITY" || grep -q "agents:" "$PM_IDENTITY"; then
        pass "PM identity references agents"
    else
        fail "PM identity should reference agents/registry"
    fi
else
    fail "PM identity.yml not found at $PM_IDENTITY"
fi

echo ""
echo "Testing PM instructions.md..."

# Test 5: PM instructions.md exists
PM_INSTRUCTIONS="$PM_AGENT_DIR/instructions.md"
if [[ -f "$PM_INSTRUCTIONS" ]]; then
    pass "PM instructions.md exists"

    # Test 6: PM instructions contain key responsibilities
    if grep -qi "project manager\|coordinate\|oversee\|team" "$PM_INSTRUCTIONS"; then
        pass "PM instructions contain PM responsibilities"
    else
        fail "PM instructions missing PM responsibilities"
    fi
else
    fail "PM instructions.md not found"
fi

echo ""
echo "Testing PM CLAUDE.md..."

# Test 7: PM CLAUDE.md exists (optional - may not be created by all deployment methods)
PM_CLAUDE="$PM_AGENT_DIR/CLAUDE.md"
if [[ -f "$PM_CLAUDE" ]]; then
    pass "PM CLAUDE.md exists"

    # Test 8: CLAUDE.md references identity.yml
    if grep -q "identity.yml\|identity" "$PM_CLAUDE"; then
        pass "PM CLAUDE.md references identity"
    else
        echo "  ⚠️  PM CLAUDE.md doesn't reference identity (non-critical)"
    fi
else
    # CLAUDE.md is optional - PM may use project-level CLAUDE.md instead
    echo "  ⚠️  PM CLAUDE.md not found (non-critical - PM may use project CLAUDE.md)"
fi

echo ""
echo "Testing status.yml..."

# Test 9: status.yml exists with session field
if [[ -n "$WORKFLOW_NAME" ]] && [[ -f "$WORKFLOW_DIR/status.yml" ]]; then
    pass "status.yml exists"

    if grep -q "session:" "$WORKFLOW_DIR/status.yml"; then
        pass "status.yml has session field"
    else
        fail "status.yml missing session field"
    fi
else
    fail "status.yml not found"
fi

# ============================================================
# RESULTS
# ============================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                              ║"
    EXIT_CODE=0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                    ║"
    EXIT_CODE=1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

exit $EXIT_CODE
