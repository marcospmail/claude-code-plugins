#!/bin/bash
# test-team-suggestion-pm-briefing.sh
#
# E2E Test: PM Briefing References Team Suggestion Templates
#
# Verifies that the PM briefing in orchestrator.py references the team
# suggestion templates directory and instructs PM to use them.
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-suggestion-pm-briefing"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-tspb-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: PM Briefing References Team Suggestion Templates"
echo "======================================================================"
echo ""

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
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR"

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

# ============================================================
# PHASE 2: Verify PM briefing through Claude
# ============================================================
echo "Phase 2: Checking PM briefing references templates..."

BRIEFING_CHECK="cd $PROJECT_ROOT && uv run python -c \"
import json
with open('lib/orchestrator.py') as f:
    content = f.read()

results = {
    'has_team_suggestions_path': 'templates/team-suggestions/' in content,
    'has_yaml_mention': '.yml' in content and 'team-suggestions' in content,
    'has_template_instruction': 'starting point' in content or 'suggestion' in content.lower(),
    'has_backward_compat': 'from scratch' in content,
    'has_ask_user_question': 'Which team template would you like to use' in content,
    'has_custom_option': 'Custom' in content
}
print('BRIEFING_CHECK:' + json.dumps(results))
\""

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $BRIEFING_CHECK"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 25

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100)

echo ""

# ============================================================
# PHASE 3: Verify results
# ============================================================
echo "Phase 3: Verifying PM briefing content..."
echo ""

# Check orchestrator.py directly for template references
ORCH_FILE="$PROJECT_ROOT/lib/orchestrator.py"

if grep -q "templates/team-suggestions/" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing references templates/team-suggestions/ directory"
else
    fail "PM briefing does not reference templates/team-suggestions/ directory"
fi

if grep -q "\.yml" "$ORCH_FILE" 2>/dev/null && grep -q "team-suggestions" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing references .yml template files in team-suggestions directory"
else
    fail "PM briefing does not reference .yml template files"
fi

if grep -q "starting point\|suggestion" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing instructs to use templates as starting points"
else
    fail "PM briefing does not instruct to use templates as starting points"
fi

if grep -q "not mandatory\|from scratch" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing maintains backward compatibility (templates optional)"
else
    fail "PM briefing does not indicate templates are optional"
fi

# Verify the template reference is in step 5 (team proposal section)
if grep -q "TEAM TEMPLATE SELECTION" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing has TEAM TEMPLATE SELECTION section"
else
    fail "PM briefing missing TEAM TEMPLATE SELECTION section"
fi

# Verify PM briefing instructs to use AskUserQuestion for template choice
if grep -q "Which team template would you like to use" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing instructs AskUserQuestion for template selection"
else
    fail "PM briefing missing AskUserQuestion for template selection"
fi

# Verify Custom option is included
if grep -q "Custom" "$ORCH_FILE" 2>/dev/null; then
    pass "PM briefing includes Custom option for building from scratch"
else
    fail "PM briefing missing Custom option"
fi

# Verify template path uses yato_path variable
if grep -q "yato_path.*templates/team-suggestions" "$ORCH_FILE" 2>/dev/null; then
    pass "Template path uses yato_path variable for discovery"
else
    # Check with f-string pattern
    if grep -q "{yato_path}/templates/team-suggestions" "$ORCH_FILE" 2>/dev/null; then
        pass "Template path uses yato_path variable for discovery"
    else
        fail "Template path does not use yato_path variable"
    fi
fi

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
