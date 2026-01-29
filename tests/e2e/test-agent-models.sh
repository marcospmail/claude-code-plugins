#!/bin/bash
# test-agent-models.sh
#
# E2E Test: Agent Model Assignment
#
# Verifies correct models are assigned:
# - code-reviewer: opus
# - developer: sonnet
# - qa: sonnet

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="agent-models"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-models-$$"

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║  E2E Test: Agent Model Assignment                            ║"
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
"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Model test" > /dev/null 2>&1

# Get workflow name and set it in the tmux session environment
WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "$WORKFLOW_NAME"
AGENTS_YML="$TEST_DIR/.workflow/$WORKFLOW_NAME/agents.yml"

# Create team with all roles to test models
tmux send-keys -t "$SESSION_NAME:0" "cd $TEST_DIR && $PROJECT_ROOT/bin/create-team.sh $TEST_DIR developer qa code-reviewer" Enter
sleep 25

echo "Testing model assignments in agents.yml..."

# Developer should use sonnet
DEV_MODEL=$(grep -A 5 "name: developer$" "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
if [[ "$DEV_MODEL" == "sonnet" ]]; then
    pass "developer uses sonnet model"
else
    fail "developer should use sonnet, got: $DEV_MODEL"
fi

# QA should use sonnet
QA_MODEL=$(grep -A 5 "name: qa$" "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
if [[ "$QA_MODEL" == "sonnet" ]]; then
    pass "qa uses sonnet model"
else
    fail "qa should use sonnet, got: $QA_MODEL"
fi

# Code-reviewer should use opus
CR_MODEL=$(grep -A 5 "name: code-reviewer$" "$AGENTS_YML" 2>/dev/null | grep "model:" | awk '{print $2}')
if [[ "$CR_MODEL" == "opus" ]]; then
    pass "code-reviewer uses opus model"
else
    fail "code-reviewer should use opus, got: $CR_MODEL"
fi

# PM should use opus (need to look in pm: section specifically)
PM_MODEL=$(sed -n '/^pm:/,/^agents:/p' "$AGENTS_YML" 2>/dev/null | grep "model:" | head -1 | awk '{print $2}')
if [[ "$PM_MODEL" == "opus" ]]; then
    pass "PM uses opus model"
else
    fail "PM should use opus, got: $PM_MODEL"
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
