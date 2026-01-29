#!/bin/bash
# test-agent-identity-files.sh
#
# E2E Test: Agent Identity and Instruction Files
#
# Verifies that agents get correct identity.yml and instructions.md files
# with proper content based on role

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-identity-files"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-identity-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Identity and Instruction Files              ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Setup
mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"
tmux new-session -d -s "$SESSION_NAME" -n "pm-checkins" -c "$TEST_DIR"
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Identity test" > /dev/null 2>&1

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "$WORKFLOW_NAME"
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

# Create team
tmux send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $PROJECT_ROOT/bin/create-team.sh $TEST_DIR developer qa code-reviewer" Enter
sleep 25

echo "Testing identity.yml files..."
echo ""

# Developer identity
DEV_IDENTITY="$WORKFLOW_PATH/agents/developer/identity.yml"
if [[ -f "$DEV_IDENTITY" ]]; then
    pass "Developer identity.yml exists"

    if grep -q "can_modify_code: true" "$DEV_IDENTITY"; then
        pass "Developer can_modify_code is true"
    else
        fail "Developer should have can_modify_code: true"
    fi

    if grep -q "role: developer" "$DEV_IDENTITY"; then
        pass "Developer role field correct"
    else
        fail "Developer role field incorrect"
    fi
else
    fail "Developer identity.yml not found"
fi

# QA identity
QA_IDENTITY="$WORKFLOW_PATH/agents/qa/identity.yml"
if [[ -f "$QA_IDENTITY" ]]; then
    pass "QA identity.yml exists"

    if grep -q "can_modify_code: false" "$QA_IDENTITY"; then
        pass "QA can_modify_code is false"
    else
        fail "QA should have can_modify_code: false"
    fi
else
    fail "QA identity.yml not found"
fi

# Code-reviewer identity
CR_IDENTITY="$WORKFLOW_PATH/agents/code-reviewer/identity.yml"
if [[ -f "$CR_IDENTITY" ]]; then
    pass "Code-reviewer identity.yml exists"

    if grep -q "can_modify_code: false" "$CR_IDENTITY"; then
        pass "Code-reviewer can_modify_code is false"
    else
        fail "Code-reviewer should have can_modify_code: false"
    fi
else
    fail "Code-reviewer identity.yml not found"
fi

echo ""
echo "Testing instructions.md files..."

# Developer instructions
DEV_INSTRUCTIONS="$WORKFLOW_PATH/agents/developer/instructions.md"
if [[ -f "$DEV_INSTRUCTIONS" ]]; then
    pass "Developer instructions.md exists"

    if grep -q "NEVER COMMUNICATE DIRECTLY WITH THE USER" "$DEV_INSTRUCTIONS"; then
        pass "Developer instructions contain communication rule"
    else
        fail "Developer instructions missing critical communication rule"
    fi

    if grep -q "notify-pm.sh" "$DEV_INSTRUCTIONS"; then
        pass "Developer instructions mention notify-pm.sh"
    else
        fail "Developer instructions should mention notify-pm.sh"
    fi
else
    fail "Developer instructions.md not found"
fi

# QA instructions should mention testing
QA_INSTRUCTIONS="$WORKFLOW_PATH/agents/qa/instructions.md"
if grep -q "Test" "$QA_INSTRUCTIONS" 2>/dev/null; then
    pass "QA instructions mention testing responsibilities"
else
    fail "QA instructions should mention testing"
fi

# Code-reviewer instructions should mention review
CR_INSTRUCTIONS="$WORKFLOW_PATH/agents/code-reviewer/instructions.md"
if grep -q "Review" "$CR_INSTRUCTIONS" 2>/dev/null || grep -q "review" "$CR_INSTRUCTIONS" 2>/dev/null; then
    pass "Code-reviewer instructions mention review responsibilities"
else
    fail "Code-reviewer instructions should mention review"
fi

# PM should have agents_registry reference
PM_IDENTITY="$WORKFLOW_PATH/agents/pm/identity.yml"
if grep -q "agents_registry:" "$PM_IDENTITY" 2>/dev/null; then
    pass "PM identity references agents_registry"
else
    fail "PM identity should reference agents_registry"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "║  ✅ ALL TESTS PASSED ($TESTS_PASSED/$((TESTS_PASSED + TESTS_FAILED)))                                  ║"
    exit 0
else
    echo "║  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)                        ║"
    exit 1
fi
echo "╚══════════════════════════════════════════════════════════════╝"
