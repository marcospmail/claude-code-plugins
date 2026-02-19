#!/bin/bash
# test-pm-constraints-complete.sh
#
# E2E Test: PM constraints.md Has Complete Constraint Sections
#
# Verifies that the PM agent's constraints.md contains both:
# 1. "System Constraints" section (shared with all agents)
# 2. "PM-Specific Constraints" section with PM-only rules
#
# Tests both generation paths:
# - init-agent-files.sh (bash)
# - agent_manager.py init-files (Python)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-constraints"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-pmconst-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: PM constraints.md Complete Sections"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() {
    echo "  PASS: $1"
    TESTS_PASSED=$((TESTS_PASSED + 1))
}

fail() {
    echo "  FAIL: $1"
    TESTS_FAILED=$((TESTS_FAILED + 1))
}

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# PHASE 1: Setup
# ============================================================
echo "Phase 1: Creating test project..."

mkdir -p "$TEST_DIR"
echo "test" > "$TEST_DIR/app.js"

cd "$TEST_DIR" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"

echo "  - Project: $TEST_DIR"
echo ""

# ============================================================
# PHASE 2: Initialize workflow
# ============================================================
echo "Phase 2: Running init-workflow.sh..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-workflow.sh '$TEST_DIR' 'Test PM constraints'" Enter
sleep 5

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" 2>/dev/null | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -z "$WORKFLOW_NAME" ]]; then
    fail "No workflow folder found"
    exit 1
fi

echo "  - Workflow: $WORKFLOW_NAME"
echo ""

# ============================================================
# PHASE 3: Create PM via init-agent-files.sh (bash path)
# ============================================================
echo "Phase 3: Creating PM via init-agent-files.sh (bash path)..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "$PROJECT_ROOT/bin/init-agent-files.sh '$TEST_DIR' pm-bash pm sonnet" Enter
sleep 5

echo "  - PM (bash) created"
echo ""

# ============================================================
# PHASE 4: Create PM via agent_manager.py (Python path)
# ============================================================
echo "Phase 4: Creating PM via agent_manager.py (Python path)..."

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "cd '$TEST_DIR' && WORKFLOW_NAME=$WORKFLOW_NAME uv run python $PROJECT_ROOT/lib/agent_manager.py init-files pm-python pm -p '$TEST_DIR'" Enter
sleep 8

echo "  - PM (python) created"
echo ""

# ============================================================
# Helper: Check PM constraints content
# ============================================================
check_pm_constraints() {
    local label="$1"
    local constraints_file="$2"

    echo "--- Checking $label ---"

    # File exists
    if [[ -f "$constraints_file" ]]; then
        pass "$label: constraints.md exists"
    else
        fail "$label: constraints.md not found at $constraints_file"
        return
    fi

    # Has System Constraints section
    if grep -q "## System Constraints" "$constraints_file" 2>/dev/null; then
        pass "$label: has '## System Constraints' section"
    else
        fail "$label: missing '## System Constraints' section"
    fi

    # Has PM-Specific Constraints section
    if grep -q "## PM-Specific Constraints" "$constraints_file" 2>/dev/null; then
        pass "$label: has '## PM-Specific Constraints' section"
    else
        fail "$label: missing '## PM-Specific Constraints' section"
    fi

    # System constraint: NEVER communicate directly with the user
    if grep -q "NEVER communicate directly with the user" "$constraints_file" 2>/dev/null; then
        pass "$label: system constraint - NEVER communicate with user"
    else
        fail "$label: missing system constraint - NEVER communicate with user"
    fi

    # System constraint: AskUserQuestion prohibition
    if grep -q "DO NOT ask the user questions using AskUserQuestion" "$constraints_file" 2>/dev/null; then
        pass "$label: system constraint - AskUserQuestion prohibition"
    else
        fail "$label: missing system constraint - AskUserQuestion prohibition"
    fi

    # System constraint: infinite polling
    if grep -qi "polling\|infinite" "$constraints_file" 2>/dev/null; then
        pass "$label: system constraint - polling prohibition"
    else
        fail "$label: missing system constraint - polling prohibition"
    fi

    # PM-specific: cannot modify code
    if grep -qi "cannot modify.*code\|cannot write.*code" "$constraints_file" 2>/dev/null; then
        pass "$label: PM constraint - cannot modify code"
    else
        fail "$label: missing PM constraint - cannot modify code"
    fi

    # PM-specific: cancel-checkin prohibition
    if grep -q "NEVER call cancel-checkin" "$constraints_file" 2>/dev/null; then
        pass "$label: PM constraint - NEVER call cancel-checkin"
    else
        fail "$label: missing PM constraint - NEVER call cancel-checkin"
    fi

    # PM-specific: tasks.json rule - skip updating
    if grep -q "NEVER skip updating tasks.json" "$constraints_file" 2>/dev/null; then
        pass "$label: PM constraint - NEVER skip updating tasks.json"
    else
        fail "$label: missing PM constraint - NEVER skip updating tasks.json"
    fi

    # PM-specific: tasks.json rule - write to agent-tasks.md
    if grep -q "NEVER write to agent-tasks.md without" "$constraints_file" 2>/dev/null; then
        pass "$label: PM constraint - NEVER write agent-tasks.md without tasks.json"
    else
        fail "$label: missing PM constraint - NEVER write agent-tasks.md without tasks.json"
    fi

    # PM-specific: do not run tests directly
    if grep -qi "do not run tests directly" "$constraints_file" 2>/dev/null; then
        pass "$label: PM constraint - do not run tests directly"
    else
        fail "$label: missing PM constraint - do not run tests directly"
    fi

    # PM-specific: do not make git commits
    if grep -qi "do not make git commits" "$constraints_file" 2>/dev/null; then
        pass "$label: PM constraint - do not make git commits"
    else
        fail "$label: missing PM constraint - do not make git commits"
    fi

    echo ""
}

# ============================================================
# PHASE 5: Verify PM (bash path) constraints.md
# ============================================================
echo "Phase 5: Verifying PM constraints (bash path)..."
echo ""

PM_BASH_CONSTRAINTS="$WORKFLOW_PATH/agents/pm-bash/constraints.md"
check_pm_constraints "PM-bash" "$PM_BASH_CONSTRAINTS"

# ============================================================
# PHASE 6: Verify PM (Python path) constraints.md
# ============================================================
echo "Phase 6: Verifying PM constraints (Python path)..."
echo ""

PM_PYTHON_CONSTRAINTS="$WORKFLOW_PATH/agents/pm-python/constraints.md"
check_pm_constraints "PM-python" "$PM_PYTHON_CONSTRAINTS"

# ============================================================
# PHASE 7: Verify both paths produce consistent content
# ============================================================
echo "Phase 7: Verifying consistency between bash and Python paths..."

if [[ -f "$PM_BASH_CONSTRAINTS" ]] && [[ -f "$PM_PYTHON_CONSTRAINTS" ]]; then
    # Both should have the same sections
    BASH_SECTIONS=$(grep "^## " "$PM_BASH_CONSTRAINTS" 2>/dev/null | sort)
    PYTHON_SECTIONS=$(grep "^## " "$PM_PYTHON_CONSTRAINTS" 2>/dev/null | sort)

    if [[ "$BASH_SECTIONS" == "$PYTHON_SECTIONS" ]]; then
        pass "Both paths produce same section headers"
    else
        fail "Section headers differ between bash and Python paths"
        echo "       Bash:   $BASH_SECTIONS"
        echo "       Python: $PYTHON_SECTIONS"
    fi

    # Both should have cancel-checkin prohibition
    BASH_HAS_CANCEL=$(grep -c "cancel-checkin" "$PM_BASH_CONSTRAINTS" 2>/dev/null)
    PYTHON_HAS_CANCEL=$(grep -c "cancel-checkin" "$PM_PYTHON_CONSTRAINTS" 2>/dev/null)

    if [[ "$BASH_HAS_CANCEL" -gt 0 ]] && [[ "$PYTHON_HAS_CANCEL" -gt 0 ]]; then
        pass "Both paths include cancel-checkin prohibition"
    else
        fail "cancel-checkin prohibition missing in one path (bash=$BASH_HAS_CANCEL, python=$PYTHON_HAS_CANCEL)"
    fi
else
    fail "Cannot compare - one or both constraint files missing"
fi

echo ""

# ============================================================
# RESULTS
# ============================================================
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    EXIT_CODE=0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    EXIT_CODE=1
fi
echo "======================================================================"
echo ""

exit $EXIT_CODE
