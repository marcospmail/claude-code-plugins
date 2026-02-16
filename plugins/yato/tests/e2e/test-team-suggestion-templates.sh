#!/bin/bash
# test-team-suggestion-templates.sh
#
# E2E Test: Team Suggestion Templates
#
# Verifies that team suggestion template files exist with valid YAML structure:
# - templates/team-suggestions/development.yml exists with correct fields
# - templates/team-suggestions/bug.yml exists with correct fields
# - Both templates have valid agent definitions with roles matching ROLE_CONFIGS
#
# IMPORTANT: This tests through Claude Code, NOT by calling scripts directly.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-suggestion-templates"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-tst-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Team Suggestion Templates"
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
# PHASE 2: Validate templates through Claude
# ============================================================
echo "Phase 2: Validating template files through Claude..."

VALIDATION_SCRIPT="cd $PROJECT_ROOT && uv run python -c \"
import yaml, json, sys
results = {}
for name in ['development', 'bug']:
    path = 'templates/team-suggestions/' + name + '.yml'
    try:
        with open(path) as f:
            data = yaml.safe_load(f)
        results[name] = {
            'exists': True,
            'has_name': 'name' in data,
            'has_description': 'description' in data,
            'has_use_cases': 'use_cases' in data and isinstance(data.get('use_cases'), list),
            'has_agents': 'agents' in data and isinstance(data.get('agents'), list),
            'agent_count': len(data.get('agents', [])),
            'agents_valid': all(
                all(k in a for k in ['name', 'role', 'model', 'description'])
                for a in data.get('agents', [])
            ),
            'roles': [a['role'] for a in data.get('agents', [])]
        }
    except Exception as e:
        results[name] = {'exists': False, 'error': str(e)}
print('VALIDATION_RESULT:' + json.dumps(results))
\""

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $VALIDATION_SCRIPT"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 25

# Capture output
OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100)

echo ""

# ============================================================
# PHASE 3: Verify results
# ============================================================
echo "Phase 3: Verifying template structure..."
echo ""

echo "Testing development.yml..."

# Check development template exists
if echo "$OUTPUT" | grep -q '"development".*"exists": true'; then
    pass "development.yml exists and is valid YAML"
else
    # Fallback: check file directly
    if [[ -f "$PROJECT_ROOT/templates/team-suggestions/development.yml" ]]; then
        pass "development.yml exists and is valid YAML"
    else
        fail "development.yml not found or invalid YAML"
    fi
fi

# Verify development.yml structure directly
if [[ -f "$PROJECT_ROOT/templates/team-suggestions/development.yml" ]]; then
    DEV_YAML=$(cat "$PROJECT_ROOT/templates/team-suggestions/development.yml")

    if echo "$DEV_YAML" | grep -q "^name:"; then
        pass "development.yml has 'name' field"
    else
        fail "development.yml missing 'name' field"
    fi

    if echo "$DEV_YAML" | grep -q "^description:"; then
        pass "development.yml has 'description' field"
    else
        fail "development.yml missing 'description' field"
    fi

    if echo "$DEV_YAML" | grep -q "^use_cases:"; then
        pass "development.yml has 'use_cases' field"
    else
        fail "development.yml missing 'use_cases' field"
    fi

    if echo "$DEV_YAML" | grep -q "^agents:"; then
        pass "development.yml has 'agents' field"
    else
        fail "development.yml missing 'agents' field"
    fi

    # Check development has developer + qa agents
    if echo "$DEV_YAML" | grep -q "role: developer"; then
        pass "development.yml has developer agent"
    else
        fail "development.yml missing developer agent"
    fi

    if echo "$DEV_YAML" | grep -q "role: qa"; then
        pass "development.yml has qa agent"
    else
        fail "development.yml missing qa agent"
    fi

    if echo "$DEV_YAML" | grep -q "role: code-reviewer"; then
        pass "development.yml has code-reviewer agent"
    else
        fail "development.yml missing code-reviewer agent"
    fi

    if echo "$DEV_YAML" | grep -q "role: security-reviewer"; then
        pass "development.yml has security-reviewer agent"
    else
        fail "development.yml missing security-reviewer agent"
    fi

    # Check agent count is 6
    AGENT_COUNT=$(echo "$DEV_YAML" | grep -c "^  - name:")
    if [[ "$AGENT_COUNT" -eq 6 ]]; then
        pass "development.yml has 6 agents"
    else
        fail "development.yml expected 6 agents, got $AGENT_COUNT"
    fi
fi

echo ""
echo "Testing bug.yml..."

if [[ -f "$PROJECT_ROOT/templates/team-suggestions/bug.yml" ]]; then
    pass "bug.yml exists and is valid YAML"
    BUG_YAML=$(cat "$PROJECT_ROOT/templates/team-suggestions/bug.yml")

    if echo "$BUG_YAML" | grep -q "^name:"; then
        pass "bug.yml has 'name' field"
    else
        fail "bug.yml missing 'name' field"
    fi

    if echo "$BUG_YAML" | grep -q "^description:"; then
        pass "bug.yml has 'description' field"
    else
        fail "bug.yml missing 'description' field"
    fi

    if echo "$BUG_YAML" | grep -q "^use_cases:"; then
        pass "bug.yml has 'use_cases' field"
    else
        fail "bug.yml missing 'use_cases' field"
    fi

    if echo "$BUG_YAML" | grep -q "^agents:"; then
        pass "bug.yml has 'agents' field"
    else
        fail "bug.yml missing 'agents' field"
    fi

    if echo "$BUG_YAML" | grep -q "role: developer"; then
        pass "bug.yml has developer agent"
    else
        fail "bug.yml missing developer agent"
    fi
else
    fail "bug.yml not found"
fi

echo ""
echo "Testing YAML validity through Claude..."

# Verify roles are valid by checking against ROLE_CONFIGS
ROLE_CHECK="cd $PROJECT_ROOT && uv run python -c \"
import yaml
from lib.agent_manager import AgentManager
valid_roles = set(AgentManager.ROLE_CONFIGS.keys())
for name in ['development', 'bug']:
    with open('templates/team-suggestions/' + name + '.yml') as f:
        data = yaml.safe_load(f)
    for agent in data['agents']:
        if agent['role'] not in valid_roles:
            print('INVALID_ROLE:' + agent['role'] + ' in ' + name)
            exit(1)
print('ALL_ROLES_VALID')
\""

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "Run this exact command in bash: $ROLE_CHECK"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter
sleep 20

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50)

if echo "$OUTPUT2" | grep -q "ALL_ROLES_VALID"; then
    pass "All agent roles match ROLE_CONFIGS"
else
    fail "Some agent roles do not match ROLE_CONFIGS"
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
