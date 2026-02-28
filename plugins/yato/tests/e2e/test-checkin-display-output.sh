#!/bin/bash
# test-checkin-display-output.sh
#
# E2E Test: checkin-display.sh output formatting with daemon model
#
# Verifies:
# 1. Display doesn't show script path in output
# 2. Text displays cleanly without concatenation issues
# 3. Status messages display correctly
# 4. Daemon PID status is shown
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-display-output"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-display-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: checkin-display.sh Output Formatting"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes
    if [[ -f "$TEST_DIR/.workflow/001-test/checkins.json" ]]; then
        PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid:
        print(pid)
except:
    pass
" 2>/dev/null)
        if [[ -n "$PID" ]]; then
            kill -9 "$PID" 2>/dev/null || true
        fi
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project and tmux session with Claude
# ============================================================
echo "Setting up test environment..."

mkdir -p "$TEST_DIR"

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
# Window 0 will have: pane 0 (checkin-display), and we'll use window 1 for Claude
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
for _retry in $(seq 1 5); do
    tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null && break
    sleep 1
    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
done

# Create a second window for Claude
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -n "claude" -c "$TEST_DIR"

echo "  Test directory: $TEST_DIR"
echo "  Session: $SESSION_NAME"

# Start Claude in window 1 (skip permissions to avoid blocking on bash prompts)
# Unset CLAUDECODE to allow nested Claude launch (when test runs from within Claude Code)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "unset CLAUDECODE && claude --dangerously-skip-permissions" Enter

# Wait for Claude to start and handle trust prompt
echo "  Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "  Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
    sleep 15
else
    echo "  No trust prompt found, continuing..."
    sleep 5
fi

echo "  Test environment ready"
echo ""

# ============================================================
# Test 1: Display shows "waiting for workflow" without script path
# ============================================================
echo "Test 1: Testing display without workflow..."

# Ask Claude to start checkin-display.sh in window 0
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: tmux -L $TMUX_SOCKET send-keys -t $SESSION_NAME:0 '$PROJECT_ROOT/bin/checkin-display.sh' Enter"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

# Wait for display to render with retry loop
WAITING_FOUND=false
for i in {1..5}; do
    sleep 3
    PANE_CONTENT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
    if echo "$PANE_CONTENT" | grep -q "(waiting for workflow...)"; then
        WAITING_FOUND=true
        break
    fi
done

# Check that script path is NOT in output (after initial display)
if echo "$PANE_CONTENT" | grep -q "checkin-display.sh"; then
    PATH_COUNT=$(echo "$PANE_CONTENT" | grep -c "checkin-display.sh" || echo "0")
    if [[ "$PATH_COUNT" -gt 1 ]]; then
        fail "Script path appears multiple times in output ($PATH_COUNT times)"
    else
        pass "Script path appears only once (from command, not display)"
    fi
else
    pass "No script path visible in display"
fi

# Check for "waiting for workflow" message
if [[ "$WAITING_FOUND" == "true" ]]; then
    pass "Shows 'waiting for workflow' message"
else
    fail "Missing 'waiting for workflow' message"
fi

# ============================================================
# Test 2: Display shows "no check-ins scheduled" with workflow
# ============================================================
echo ""
echo "Test 2: Testing display with workflow but no check-ins..."

# Create workflow directory
mkdir -p "$TEST_DIR/.workflow/001-test"
cat > "$TEST_DIR/.workflow/001-test/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 5
EOF

# Set WORKFLOW_NAME in tmux env
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test"

# Wait for display to refresh with retry loop
NO_CHECKINS_FOUND=false
for i in {1..5}; do
    sleep 3
    PANE_CONTENT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
    if echo "$PANE_CONTENT" | grep -q "(no check-ins scheduled)"; then
        NO_CHECKINS_FOUND=true
        break
    fi
done

if [[ "$NO_CHECKINS_FOUND" == "true" ]]; then
    pass "Shows 'no check-ins scheduled' message"
else
    fail "Missing 'no check-ins scheduled' message"
fi

# Check for text concatenation issues
if echo "$PANE_CONTENT" | grep -q "scheduled).*checkin-display\|scheduled).*yato"; then
    fail "Text concatenation issue detected"
else
    pass "No text concatenation issues"
fi

# ============================================================
# Test 3: Display shows check-in status correctly with daemon
# ============================================================
echo ""
echo "Test 3: Testing display with pending check-in and daemon..."

# Ask Claude to start the daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/checkin_scheduler.py start 5 --note 'Test check-in note' --target '$SESSION_NAME:0' --workflow '001-test'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 25
else
    sleep 25
fi

# Verify daemon was started - if not, start it directly as fallback
if [[ ! -f "$TEST_DIR/.workflow/001-test/checkins.json" ]] || ! uv run --directory "$PROJECT_ROOT" python -c "
import json
with open('$TEST_DIR/.workflow/001-test/checkins.json') as f:
    data = json.load(f)
pid = data.get('daemon_pid')
print(pid if pid else '')
" 2>/dev/null | grep -q '[0-9]'; then
    echo "  (fallback: starting daemon directly)"
    cd "$PROJECT_ROOT" && uv run python lib/checkin_scheduler.py start 5 --note 'Test check-in note' --target "$SESSION_NAME:0" --workflow '001-test' 2>/dev/null
    sleep 5
fi

# Wait for display to refresh with retry loop
PENDING_FOUND=false
NOTE_FOUND=false
DAEMON_FOUND=false
for i in {1..12}; do
    sleep 3
    PANE_CONTENT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
    if echo "$PANE_CONTENT" | grep -q "\[pending\]"; then
        PENDING_FOUND=true
    fi
    if echo "$PANE_CONTENT" | grep -q "Test check-in note"; then
        NOTE_FOUND=true
    fi
    if echo "$PANE_CONTENT" | grep -q "\[DAEMON\].*running"; then
        DAEMON_FOUND=true
    fi
    if [[ "$PENDING_FOUND" == "true" && "$NOTE_FOUND" == "true" && "$DAEMON_FOUND" == "true" ]]; then
        break
    fi
done

if [[ "$PENDING_FOUND" == "true" ]]; then
    pass "Shows [pending] status"
else
    fail "Missing [pending] status"
fi

if [[ "$NOTE_FOUND" == "true" ]]; then
    pass "Shows check-in note"
else
    fail "Missing check-in note"
fi

if [[ "$DAEMON_FOUND" == "true" ]]; then
    pass "Shows [DAEMON] running status"
else
    fail "Missing [DAEMON] running status"
fi

# ============================================================
# Test 4: Display clears properly between updates
# ============================================================
echo ""
echo "Test 4: Testing display clears properly..."

# Ask Claude to cancel the daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python lib/checkin_scheduler.py cancel --workflow '001-test'"
sleep 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
sleep 10

# Handle any prompts
SKILL_CHECK=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$SKILL_CHECK" | grep -qi "Use skill"; then
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Down Enter
    sleep 20
else
    sleep 20
fi

# Manually update checkins.json to show done entries
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << EOF
{
  "checkins": [
    {
      "id": "test456",
      "status": "done",
      "scheduled_for": "$(date +%Y-%m-%dT%H:%M:%S)",
      "completed_at": "$(date +%Y-%m-%dT%H:%M:%S)",
      "note": "Completed check-in",
      "target": "$SESSION_NAME:0"
    }
  ],
  "daemon_pid": null
}
EOF

# Wait for display to refresh with retry loop
OLD_CLEARED=false
DONE_FOUND=false
for i in {1..5}; do
    sleep 3
    PANE_CONTENT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
    if ! echo "$PANE_CONTENT" | grep -q "Test check-in note"; then
        OLD_CLEARED=true
    fi
    if echo "$PANE_CONTENT" | grep -q "\[done\]"; then
        DONE_FOUND=true
    fi
    if [[ "$OLD_CLEARED" == "true" && "$DONE_FOUND" == "true" ]]; then
        break
    fi
done

if [[ "$OLD_CLEARED" == "true" ]]; then
    pass "Old content cleared properly"
else
    fail "Old content still visible (display not clearing)"
fi

if [[ "$DONE_FOUND" == "true" ]]; then
    pass "New [done] status visible"
else
    fail "New [done] status not visible"
fi

# ============================================================
# Test 5: Pane title updates correctly (reads from status.yml)
# ============================================================
echo ""
echo "Test 5: Testing pane title updates..."

# Set interval in status.yml
sed -i '' 's/checkin_interval_minutes:.*/checkin_interval_minutes: 5/' "$TEST_DIR/.workflow/001-test/status.yml"

# Wait for title update with retry loop
TITLE_FOUND=false
for i in {1..5}; do
    sleep 3
    PANE_TITLE=$(tmux -L "$TMUX_SOCKET" display-message -t "$SESSION_NAME:0" -p '#{pane_title}' 2>/dev/null)
    if echo "$PANE_TITLE" | grep -q "every 5m"; then
        TITLE_FOUND=true
        break
    fi
done

if [[ "$TITLE_FOUND" == "true" ]]; then
    pass "Pane title shows interval from status.yml"
else
    fail "Pane title missing interval: $PANE_TITLE"
fi

# ============================================================
# Test 6: Display shows DEAD daemon status
# ============================================================
echo ""
echo "Test 6: Testing display shows dead daemon..."

# Set a fake PID that doesn't exist
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << EOF
{
  "checkins": [
    {
      "id": "test789",
      "status": "pending",
      "scheduled_for": "$(date -v +5M +%Y-%m-%dT%H:%M:%S 2>/dev/null || date -d '+5 minutes' +%Y-%m-%dT%H:%M:%S)",
      "note": "Dead daemon test",
      "target": "$SESSION_NAME:0"
    }
  ],
  "daemon_pid": 999999
}
EOF

# Wait for display to show dead daemon with retry loop
DEAD_FOUND=false
for i in {1..5}; do
    sleep 3
    PANE_CONTENT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
    if echo "$PANE_CONTENT" | grep -q "DEAD\|NO DAEMON"; then
        DEAD_FOUND=true
        break
    fi
done

if [[ "$DEAD_FOUND" == "true" ]]; then
    pass "Shows dead daemon indicator"
else
    fail "Should show dead daemon or NO DAEMON warning"
fi

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
