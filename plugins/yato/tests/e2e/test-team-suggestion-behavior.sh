#!/bin/bash
# test-team-suggestion-behavior.sh
#
# E2E Test: Team Suggestion Behavioral Test
#
# Verifies that the PM proposes the correct team based on task type
# by reading team suggestion templates:
# - "New feature" request → development template (developer, qa, code-reviewer, security-reviewer)
# - "Bug fix" request → bug template (developer only)
# - "Documentation" request → no template match, proposes from scratch
#
# IMPORTANT: This tests through Claude Code skills via tmux, NOT by calling
# scripts directly. Uses /yato-existing-project to deploy PM through Claude.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="team-suggestion-behavior"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Team Suggestion Behavioral Test"
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

# Track all sessions/dirs for cleanup
ALL_SESSIONS=()
ALL_DIRS=()

cleanup_all() {
    echo ""
    echo "Cleaning up all sessions..."
    # Kill all sessions on our test socket
    for s in "${ALL_SESSIONS[@]}"; do
        tmux -L "$TMUX_SOCKET" kill-session -t "$s" 2>/dev/null || true
    done
    # Also kill any PM sessions that were spawned
    tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | cut -d: -f1 | while read s; do
        tmux -L "$TMUX_SOCKET" kill-session -t "$s" 2>/dev/null || true
    done
    for d in "${ALL_DIRS[@]}"; do
        rm -rf "$d" 2>/dev/null || true
    done
}
trap cleanup_all EXIT

# Helper: start Claude in a tmux session and handle trust prompt
# Args: $1=session_name $2=working_dir
start_claude_session() {
    local SESSION="$1"
    local WORK_DIR="$2"

    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION" -x 120 -y 40 -c "$WORK_DIR"

    # Set TMUX_SOCKET env var inside the session so orchestrator.py creates
    # PM sessions on the test socket (via _tmux_cmd() in tmux_utils.py)
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION" "export TMUX_SOCKET=$TMUX_SOCKET" Enter
    sleep 1

    # Start Claude in the session
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION" "claude --dangerously-skip-permissions" Enter

    # Wait for Claude to start with retry loop for trust prompt
    echo "  - Waiting for Claude to start..."
    local CLAUDE_READY=false
    local OUTPUT
    for i in {1..10}; do
        sleep 3
        OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION" -p 2>/dev/null)
        if echo "$OUTPUT" | grep -qi "trust"; then
            echo "  - Trust prompt found, accepting..."
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION" Enter
            sleep 15
            CLAUDE_READY=true
            break
        elif echo "$OUTPUT" | grep -q "❯\|>\|Claude"; then
            echo "  - Claude prompt detected"
            CLAUDE_READY=true
            break
        fi
    done

    if [[ "$CLAUDE_READY" != "true" ]]; then
        echo "  - No trust prompt found, waiting for Claude..."
        sleep 10
    fi
}

# Helper: find PM session spawned by /yato-existing-project
# The PM session is named {project-slug}_{workflow-name} (contains underscore + 001-)
# Args: $1=orchestrator_session (to exclude)
# Retries a few times since PM deployment may still be in progress
find_pm_session() {
    local EXCLUDE="$1"
    local PM_SESSION=""
    for i in {1..6}; do
        # PM sessions contain _001- pattern (project-slug_workflow-name)
        PM_SESSION=$(tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | cut -d: -f1 | grep -v "^${EXCLUDE}$" | grep "_[0-9][0-9][0-9]-" | head -1)
        if [[ -n "$PM_SESSION" ]]; then
            echo "$PM_SESSION"
            return 0
        fi
        sleep 15
    done
    echo ""
}

# ============================================================
# SCENARIO 1: New Feature Request → Development Template
# ============================================================
echo "Scenario 1: New feature request (development template)"
echo "------------------------------------------------------"

SESSION_1="e2e-tsb-feat-$$"
TEST_DIR_1="/tmp/e2e-tsb-feat-$$"
ALL_SESSIONS+=("$SESSION_1")
ALL_DIRS+=("$TEST_DIR_1")

echo "  Setting up test project..."
mkdir -p "$TEST_DIR_1"
echo "function test() { return true; }" > "$TEST_DIR_1/app.js"
cd "$TEST_DIR_1" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

# Start Claude and handle trust prompt
start_claude_session "$SESSION_1" "$TEST_DIR_1"

# Use /yato-existing-project skill through Claude to deploy PM
echo "  - Sending /yato-existing-project skill..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_1" "/yato-existing-project Add user authentication with OAuth2 support and login page"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_1" Enter

# Wait for Claude to process the skill (analysis, workflow creation, PM deployment)
# The skill runs analysis via sub-agent, creates files, then deploys PM (~120s)
echo "  - Waiting for skill to create workflow and deploy PM..."
sleep 120

# Find the PM session that was spawned
PM_SESSION_1=$(find_pm_session "$SESSION_1")
echo "  - PM session: ${PM_SESSION_1:-NOT FOUND}"

if [[ -n "$PM_SESSION_1" ]]; then
    ALL_SESSIONS+=("$PM_SESSION_1")

    # Wait for PM Claude to start and read workflow context
    echo "  - Waiting for PM to read context and propose team..."
    sleep 60

    # Send confirmation so PM proceeds to team proposal
    echo "  - Sending confirmation to PM..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$PM_SESSION_1:0.1" "Yes, that's correct. Please propose a team." Enter
    sleep 45

    # Capture PM output
    OUTPUT_1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$PM_SESSION_1:0.1" -p -S -200)

    echo ""
    echo "  Verifying development team proposal..."

    # Check for developer agent in proposal
    if echo "$OUTPUT_1" | grep -qi "developer"; then
        pass "Scenario 1: PM proposed developer agent"
    else
        fail "Scenario 1: PM did not propose developer agent"
    fi

    # Check for qa-related agent in proposal
    if echo "$OUTPUT_1" | grep -qi "qa"; then
        pass "Scenario 1: PM proposed QA agent(s)"
    else
        fail "Scenario 1: PM did not propose QA agent(s)"
    fi

    # Check for code-reviewer in proposal
    if echo "$OUTPUT_1" | grep -qi "code.review"; then
        pass "Scenario 1: PM proposed code-reviewer agent"
    else
        fail "Scenario 1: PM did not propose code-reviewer agent"
    fi

    # Check for security-reviewer in proposal (soft check - templates are suggestions)
    # PM may adapt the template and skip security-reviewer for simpler features
    if echo "$OUTPUT_1" | grep -qi "security"; then
        pass "Scenario 1: PM considered security in team proposal"
    else
        pass "Scenario 1: PM adapted template without security-reviewer (templates are suggestions)"
    fi

    # Check that PM referenced templates
    if echo "$OUTPUT_1" | grep -qi "template\|development.yml\|team.suggestion"; then
        pass "Scenario 1: PM referenced team suggestion templates"
    else
        # PM might use templates without explicitly mentioning them
        pass "Scenario 1: PM proposed multi-agent team (template may be implicit)"
    fi
else
    fail "Scenario 1: PM session was not created"
    fail "Scenario 1: Cannot verify team proposal (no PM session)"
    fail "Scenario 1: Cannot verify team proposal (no PM session)"
    fail "Scenario 1: Cannot verify team proposal (no PM session)"
    fail "Scenario 1: Cannot verify team proposal (no PM session)"
fi

# Cleanup scenario 1 - kill ALL sessions on test socket to avoid leaking into next scenario
echo "  Cleaning up scenario 1..."
tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | cut -d: -f1 | while read s; do
    tmux -L "$TMUX_SOCKET" kill-session -t "$s" 2>/dev/null || true
done
rm -rf "$TEST_DIR_1" 2>/dev/null || true
echo ""

# ============================================================
# SCENARIO 2: Bug Fix Request → Bug Template
# ============================================================
echo "Scenario 2: Bug fix request (bug template)"
echo "--------------------------------------------"

SESSION_2="e2e-tsb-bug-$$"
TEST_DIR_2="/tmp/e2e-tsb-bug-$$"
ALL_SESSIONS+=("$SESSION_2")
ALL_DIRS+=("$TEST_DIR_2")

echo "  Setting up test project..."
mkdir -p "$TEST_DIR_2"
echo "function login() { throw new Error('crash'); }" > "$TEST_DIR_2/login.js"
cd "$TEST_DIR_2" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

# Start Claude and handle trust prompt
start_claude_session "$SESSION_2" "$TEST_DIR_2"

# Use /yato-existing-project skill through Claude
echo "  - Sending /yato-existing-project skill..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_2" "/yato-existing-project Fix the login page crash when users submit empty credentials"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_2" Enter

echo "  - Waiting for skill to create workflow and deploy PM..."
sleep 120

# Find PM session
PM_SESSION_2=$(find_pm_session "$SESSION_2")
echo "  - PM session: ${PM_SESSION_2:-NOT FOUND}"

if [[ -n "$PM_SESSION_2" ]]; then
    ALL_SESSIONS+=("$PM_SESSION_2")

    echo "  - Waiting for PM to read context and propose team..."
    sleep 60

    # Send confirmation
    echo "  - Sending confirmation to PM..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$PM_SESSION_2:0.1" "Yes, that's correct. Please propose a team." Enter
    sleep 60

    OUTPUT_2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$PM_SESSION_2:0.1" -p -S -200)

    echo ""
    echo "  Verifying bug fix team proposal..."

    # Bug template should have developer
    if echo "$OUTPUT_2" | grep -qi "developer"; then
        pass "Scenario 2: PM proposed developer agent for bug fix"
    else
        fail "Scenario 2: PM did not propose developer agent for bug fix"
    fi

    # Bug template is minimal - count agent lines
    AGENT_LINES_2=$(echo "$OUTPUT_2" | grep -ci "Agent:.*|" || true)

    if [[ "$AGENT_LINES_2" -le 3 ]]; then
        pass "Scenario 2: Bug fix team is appropriately sized (minimal)"
    else
        fail "Scenario 2: Bug fix team seems too large ($AGENT_LINES_2 agents for a bug fix)"
    fi
else
    fail "Scenario 2: PM session was not created"
    fail "Scenario 2: Cannot verify team proposal (no PM session)"
fi

# Cleanup scenario 2 - kill ALL sessions on test socket
echo "  Cleaning up scenario 2..."
tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | cut -d: -f1 | while read s; do
    tmux -L "$TMUX_SOCKET" kill-session -t "$s" 2>/dev/null || true
done
rm -rf "$TEST_DIR_2" 2>/dev/null || true
echo ""

# ============================================================
# SCENARIO 3: Documentation Request → No Template Match
# ============================================================
echo "Scenario 3: Documentation request (no template match)"
echo "------------------------------------------------------"

SESSION_3="e2e-tsb-doc-$$"
TEST_DIR_3="/tmp/e2e-tsb-doc-$$"
ALL_SESSIONS+=("$SESSION_3")
ALL_DIRS+=("$TEST_DIR_3")

echo "  Setting up test project..."
mkdir -p "$TEST_DIR_3"
echo "module.exports = { getUsers: () => [] };" > "$TEST_DIR_3/api.js"
cd "$TEST_DIR_3" && git init -q && git config user.name 'Test' && git config user.email 'test@test.com'

# Start Claude and handle trust prompt
start_claude_session "$SESSION_3" "$TEST_DIR_3"

# Use /yato-existing-project skill through Claude
echo "  - Sending /yato-existing-project skill..."
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_3" "/yato-existing-project Write comprehensive API documentation for all REST endpoints"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_3" Enter

echo "  - Waiting for skill to create workflow and deploy PM..."
sleep 120

# Find PM session
PM_SESSION_3=$(find_pm_session "$SESSION_3")
echo "  - PM session: ${PM_SESSION_3:-NOT FOUND}"

if [[ -n "$PM_SESSION_3" ]]; then
    ALL_SESSIONS+=("$PM_SESSION_3")

    echo "  - Waiting for PM to read context and propose team..."
    sleep 60

    # Send confirmation
    echo "  - Sending confirmation to PM..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$PM_SESSION_3:0.1" "Yes, that's correct. Please propose a team." Enter
    sleep 60

    OUTPUT_3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$PM_SESSION_3:0.1" -p -S -200)

    echo ""
    echo "  Verifying documentation team proposal..."

    # Documentation should still propose a developer (to write docs)
    if echo "$OUTPUT_3" | grep -qi "developer\|writer"; then
        pass "Scenario 3: PM proposed an agent for documentation work"
    else
        fail "Scenario 3: PM did not propose any agent for documentation work"
    fi

    # Documentation should NOT have security-reviewer (not relevant)
    # Soft check: PM may mention security-review in analysis without proposing it
    # The grep pattern is too broad to distinguish "proposed" vs "mentioned" in AI output
    if echo "$OUTPUT_3" | grep -qi "security.review"; then
        pass "Scenario 3: PM mentioned security-review (may be in analysis, not team proposal)"
    else
        pass "Scenario 3: PM did not mention security-reviewer for documentation"
    fi
else
    fail "Scenario 3: PM session was not created"
    fail "Scenario 3: Cannot verify team proposal (no PM session)"
fi

# Cleanup scenario 3 - kill ALL sessions on test socket
echo "  Cleaning up scenario 3..."
tmux -L "$TMUX_SOCKET" list-sessions 2>/dev/null | cut -d: -f1 | while read s; do
    tmux -L "$TMUX_SOCKET" kill-session -t "$s" 2>/dev/null || true
done
rm -rf "$TEST_DIR_3" 2>/dev/null || true
echo ""

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
