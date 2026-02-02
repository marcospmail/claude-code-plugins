#!/bin/bash
# test-checkin-display-output.sh
#
# E2E Test: checkin-display.sh output formatting
#
# Verifies:
# 1. Display doesn't show script path in output
# 2. Text displays cleanly without concatenation issues
# 3. Status messages display correctly

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-display-output"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
BIN_DIR="$PROJECT_ROOT/bin"
SESSION_NAME="e2e-display-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: checkin-display.sh Output Formatting"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# ============================================================
# Setup: Create test project and tmux session
# ============================================================

mkdir -p "$TEST_DIR"

# Create tmux session WITHOUT workflow first
tmux new-session -d -s "$SESSION_NAME" -c "$TEST_DIR"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# ============================================================
# Test 1: Display shows "waiting for workflow" without script path
# ============================================================

echo "Testing display without workflow..."

# Start checkin-display.sh in the session
tmux send-keys -t "$SESSION_NAME:0" "$BIN_DIR/checkin-display.sh" Enter

# Wait for display to render
sleep 5

# Capture pane content
PANE_CONTENT=$(tmux capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)

# Check that script path is NOT in output (after initial display)
if echo "$PANE_CONTENT" | grep -q "checkin-display.sh"; then
    # Script path might appear once from the command, but shouldn't be in the display area
    # Count occurrences
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
if echo "$PANE_CONTENT" | grep -q "(waiting for workflow...)"; then
    pass "Shows 'waiting for workflow' message"
else
    fail "Missing 'waiting for workflow' message"
fi

# ============================================================
# Test 2: Display shows "no check-ins scheduled" with workflow
# ============================================================

echo ""
echo "Testing display with workflow but no check-ins..."

# Create workflow directory
mkdir -p "$TEST_DIR/.workflow/001-test"
cat > "$TEST_DIR/.workflow/001-test/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 5
EOF

# Set WORKFLOW_NAME in tmux env
tmux setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test"

# Wait for display to refresh
sleep 6

# Capture pane content
PANE_CONTENT=$(tmux capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)

# Check for "no check-ins scheduled" message
if echo "$PANE_CONTENT" | grep -q "(no check-ins scheduled)"; then
    pass "Shows 'no check-ins scheduled' message"
else
    fail "Missing 'no check-ins scheduled' message"
fi

# Check for text concatenation issues (script path mixed with message)
if echo "$PANE_CONTENT" | grep -q "scheduled).*checkin-display\|scheduled).*yato"; then
    fail "Text concatenation issue detected"
else
    pass "No text concatenation issues"
fi

# ============================================================
# Test 3: Display shows check-in status correctly
# ============================================================

echo ""
echo "Testing display with pending check-in..."

# Create checkins.json with a pending check-in
FUTURE_TIME=$(date -v +5M +"%Y-%m-%dT%H:%M:%S" 2>/dev/null || date -d "+5 minutes" +"%Y-%m-%dT%H:%M:%S")
cat > "$TEST_DIR/.workflow/001-test/checkins.json" << EOF
{
  "checkins": [
    {
      "id": "test123",
      "status": "pending",
      "scheduled_for": "$FUTURE_TIME",
      "note": "Test check-in note",
      "target": "$SESSION_NAME:0",
      "created_at": "$(date +%Y-%m-%dT%H:%M:%S)"
    }
  ]
}
EOF

# Wait for display to refresh with retry loop (more robust under load)
# Display refreshes every 2s, we'll retry up to 8 times (16 seconds total)
PENDING_FOUND=false
NOTE_FOUND=false
for i in {1..8}; do
    sleep 2
    PANE_CONTENT=$(tmux capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
    if echo "$PANE_CONTENT" | grep -q "\[pending\]"; then
        PENDING_FOUND=true
    fi
    if echo "$PANE_CONTENT" | grep -q "Test check-in note"; then
        NOTE_FOUND=true
    fi
    if [[ "$PENDING_FOUND" == "true" && "$NOTE_FOUND" == "true" ]]; then
        break
    fi
done

# Check for pending indicator
if [[ "$PENDING_FOUND" == "true" ]]; then
    pass "Shows [pending] status"
else
    fail "Missing [pending] status"
fi

# Check for note content
if [[ "$NOTE_FOUND" == "true" ]]; then
    pass "Shows check-in note"
else
    fail "Missing check-in note"
fi

# ============================================================
# Test 4: Display clears properly between updates
# ============================================================

echo ""
echo "Testing display clears properly..."

# Update checkins.json to change content
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
  ]
}
EOF

# Wait for display to refresh
sleep 6

# Capture pane content
PANE_CONTENT=$(tmux capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)

# Old content should be gone
if echo "$PANE_CONTENT" | grep -q "Test check-in note"; then
    fail "Old content still visible (display not clearing)"
else
    pass "Old content cleared properly"
fi

# New content should be visible
if echo "$PANE_CONTENT" | grep -q "\[done\]"; then
    pass "New [done] status visible"
else
    fail "New [done] status not visible"
fi

# ============================================================
# Test 5: Pane title updates correctly
# ============================================================

echo ""
echo "Testing pane title updates..."

# Create interval file
echo "5" > "$TEST_DIR/.workflow/001-test/checkin_interval.txt"

# Wait for title update
sleep 4

# Get pane title
PANE_TITLE=$(tmux display-message -t "$SESSION_NAME:0" -p '#{pane_title}' 2>/dev/null)

if echo "$PANE_TITLE" | grep -q "every 5m"; then
    pass "Pane title shows interval"
else
    fail "Pane title missing interval: $PANE_TITLE"
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
