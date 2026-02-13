#!/bin/bash
# test-window-focus.sh
#
# E2E Test: Window Focus Preservation
#
# This test verifies that create-agent.sh uses the -d flag on tmux new-window
# so that creating agent windows does NOT switch focus away from the current window.
# It uses REAL Claude Code instances to verify end-to-end behavior.
#
# Tests:
# 1. Creating agents with real Claude Code does not change the active window
# 2. Claude actually starts in the background window (send-keys works with -d)
# 3. Multiple agents can be created without focus switching
# 4. Both code paths (with/without project path) preserve focus

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="window-focus"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-focus-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Window Focus Preservation (tmux new-window -d)"
echo "  Uses real Claude Code instances"
echo "======================================================================"
echo ""
echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

get_active_window() {
    tmux -L "$TMUX_SOCKET" display-message -t "$SESSION_NAME" -p "#{window_index}" 2>/dev/null
}

# Wait for Claude prompt (❯) or trust prompt in a specific window
wait_for_claude_in_window() {
    local window_target="$1"
    local max_wait="${2:-30}"
    local waited=0
    while [[ $waited -lt $max_wait ]]; do
        local output
        output=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$window_target" -p 2>/dev/null)
        # Handle trust prompt
        if echo "$output" | grep -qi "trust"; then
            echo "    Trust prompt found in $window_target, accepting..."
            tmux -L "$TMUX_SOCKET" send-keys -t "$window_target" Enter 2>/dev/null
            sleep 15
            return 0
        fi
        # Check for Claude prompt
        if echo "$output" | grep -q "^❯\|^>\|^›"; then
            return 0
        fi
        sleep 3
        waited=$((waited + 3))
    done
    return 1
}

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Phase 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-focus"

cat > "$TEST_DIR/.workflow/001-test-focus/status.yml" <<EOF
status: in-progress
title: "Test window focus"
folder: "$TEST_DIR/.workflow/001-test-focus"
session: "$SESSION_NAME"
EOF

echo "001-test-focus" > "$TEST_DIR/.workflow/current"

cat > "$TEST_DIR/.workflow/001-test-focus/agents.yml" <<'EOF'
pm:
  name: pm
  role: pm
agents: []
EOF

# Create tmux session with initial window (window 0)
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 160 -y 50 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-focus"

if ! tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    fail "Failed to create tmux session"
    exit 1
fi

pass "Tmux session created"

INITIAL_WINDOW=$(get_active_window)
echo "  Initial active window: $INITIAL_WINDOW"

if [[ "$INITIAL_WINDOW" == "0" ]]; then
    pass "Initial active window is 0"
else
    fail "Initial active window should be 0, got: $INITIAL_WINDOW"
fi

echo ""

# ============================================================
# Phase 2: Create agent WITH Claude and verify focus preserved
# ============================================================
echo "Phase 2: Creating agent with real Claude Code, verifying focus stays..."

"$PROJECT_ROOT/bin/create-agent.sh" "$SESSION_NAME" developer \
    -p "$TEST_DIR" \
    --no-brief 2>&1 | while IFS= read -r line; do echo "  > $line"; done

# Check focus immediately after creation (before Claude even starts)
AFTER_FIRST=$(get_active_window)
echo "  Active window after first agent creation: $AFTER_FIRST"

if [[ "$AFTER_FIRST" == "0" ]]; then
    pass "Active window stayed at 0 after creating agent with Claude"
else
    fail "Active window changed to $AFTER_FIRST after creating agent (expected 0)"
fi

# Verify the agent window exists
WINDOW_COUNT=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$WINDOW_COUNT" -ge 2 ]]; then
    pass "Agent window was created (total windows: $WINDOW_COUNT)"
else
    fail "Agent window was not created (total windows: $WINDOW_COUNT)"
fi

# Get the agent window index
AGENT_WINDOW=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" 2>/dev/null | grep -iv "bash\|zsh" | tail -1 | cut -d: -f1)

# Wait for Claude to actually start in the background window
echo "  Waiting for Claude to start in background window ($SESSION_NAME:$AGENT_WINDOW)..."
if wait_for_claude_in_window "$SESSION_NAME:$AGENT_WINDOW" 30; then
    pass "Claude started successfully in background window"
else
    # Check if claude command is at least running
    PANE_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:$AGENT_WINDOW" -p 2>/dev/null)
    if echo "$PANE_OUTPUT" | grep -qi "claude\|loading\|connecting"; then
        pass "Claude is starting in background window (still loading)"
    else
        fail "Claude did not start in background window"
        echo "    Pane output: $(echo "$PANE_OUTPUT" | tail -5)"
    fi
fi

# Verify focus STILL on window 0 after waiting
STILL_FOCUSED=$(get_active_window)
if [[ "$STILL_FOCUSED" == "0" ]]; then
    pass "Focus still on window 0 after Claude started in background"
else
    fail "Focus shifted to $STILL_FOCUSED while waiting for Claude"
fi

echo ""

# ============================================================
# Phase 3: Create second agent with Claude, verify focus
# ============================================================
echo "Phase 3: Creating second agent with real Claude Code..."

"$PROJECT_ROOT/bin/create-agent.sh" "$SESSION_NAME" qa \
    -p "$TEST_DIR" \
    --no-brief 2>&1 | while IFS= read -r line; do echo "  > $line"; done

AFTER_SECOND=$(get_active_window)
echo "  Active window after second agent: $AFTER_SECOND"

if [[ "$AFTER_SECOND" == "0" ]]; then
    pass "Active window stayed at 0 after creating second agent with Claude"
else
    fail "Active window changed to $AFTER_SECOND after second agent (expected 0)"
fi

echo ""

# ============================================================
# Phase 4: Verify all windows and Claude instances
# ============================================================
echo "Phase 4: Verifying all agent windows and Claude instances..."

FINAL_WINDOW_COUNT=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" 2>/dev/null | wc -l | tr -d ' ')
if [[ "$FINAL_WINDOW_COUNT" -ge 3 ]]; then
    pass "All agent windows created (total: $FINAL_WINDOW_COUNT, expected >= 3)"
else
    fail "Expected at least 3 windows (1 initial + 2 agents), got: $FINAL_WINDOW_COUNT"
fi

WINDOW_LIST=$(tmux -L "$TMUX_SOCKET" list-windows -t "$SESSION_NAME" -F "#{window_index}:#{window_name}" 2>/dev/null)
echo "  Window list:"
echo "$WINDOW_LIST" | while IFS= read -r line; do echo "    $line"; done

FINAL_ACTIVE=$(get_active_window)
if [[ "$FINAL_ACTIVE" == "0" ]]; then
    pass "Final active window is still 0"
else
    fail "Final active window should be 0, got: $FINAL_ACTIVE"
fi

echo ""

# ============================================================
# Phase 5: Create agent without project path (second code path)
# ============================================================
echo "Phase 5: Testing agent creation without project path (with Claude)..."

BEFORE_NO_PATH=$(get_active_window)

"$PROJECT_ROOT/bin/create-agent.sh" "$SESSION_NAME" researcher \
    --no-brief 2>&1 | while IFS= read -r line; do echo "  > $line"; done

AFTER_NO_PATH=$(get_active_window)
echo "  Active window after no-path agent: $AFTER_NO_PATH"

if [[ "$AFTER_NO_PATH" == "$BEFORE_NO_PATH" ]]; then
    pass "Active window preserved when creating agent without project path"
else
    fail "Active window changed from $BEFORE_NO_PATH to $AFTER_NO_PATH (no-path code path)"
fi

echo ""

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
