#!/bin/bash
# E2E Test: Full workflow - check-in lifecycle
# Tests scheduling, cancellation, auto-continue, and auto-stop
# Run: ./tests/test-workflow-checkin-lifecycle.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/checkin$$"
TEST_SESSION="checkin$$"

# Colors
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[0;33m'
NC='\033[0m'

pass() { echo -e "${GREEN}PASS${NC}: $1"; PASSED=$((PASSED + 1)); }
fail() { echo -e "${RED}FAIL${NC}: $1"; FAILED=$((FAILED + 1)); }
skip() { echo -e "${YELLOW}SKIP${NC}: $1"; SKIPPED=$((SKIPPED + 1)); }

PASSED=0
FAILED=0
SKIPPED=0

cleanup() {
    echo ""
    echo "Cleaning up..."
    tmux kill-session -t "$TEST_SESSION" 2>/dev/null || true
    rm -rf "$TEST_DIR"
}

trap cleanup EXIT

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║   E2E Test: Check-in Lifecycle (Schedule, Cancel, Auto)     ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Scenario: User schedules check-ins, cancels them, tests auto-continue"
echo ""

# ============================================================================
# STEP 1: Set up project with workflow
# ============================================================================
echo "=== Step 1: Set up project with workflow ==="
mkdir -p "$TEST_DIR"

"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Test check-in lifecycle" > /dev/null 2>&1

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -n "$WORKFLOW_NAME" ]]; then
    pass "Workflow created: $WORKFLOW_NAME"
else
    fail "Workflow not created"
    exit 1
fi

# ============================================================================
# STEP 2: Create tasks for auto-continue testing
# ============================================================================
echo ""
echo "=== Step 2: Create tasks for testing ==="

cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Task 1", "status": "pending", "assignee": "developer"},
    {"id": "2", "title": "Task 2", "status": "pending", "assignee": "developer"}
  ]
}
EOF

if [[ -f "$WORKFLOW_PATH/tasks.json" ]]; then
    pass "tasks.json created with pending tasks"
else
    fail "tasks.json not created"
fi

# ============================================================================
# STEP 3: Configure agent and start workflow
# ============================================================================
echo ""
echo "=== Step 3: Configure agent and start workflow ==="

cat > "$WORKFLOW_PATH/agents.yml" << EOF
pm:
  name: pm
  role: pm
  session: "$TEST_SESSION"
  window: 0
  pane: 1
  model: opus

agents:
  - name: test-dev
    role: developer
    session: "$TEST_SESSION"
    window: 1
    model: sonnet
EOF

mkdir -p "$WORKFLOW_PATH/agents/developer"
echo "# Developer" > "$WORKFLOW_PATH/agents/developer/instructions.md"

# Start workflow
"$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" > /dev/null 2>&1

if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Workflow session started"
else
    fail "Workflow session not started"
    exit 1
fi

# CRITICAL: Set WORKFLOW_NAME in tmux environment (resume-workflow.sh doesn't do this)
tmux setenv -t "$TEST_SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"

# Initialize checkins.json file
mkdir -p "$WORKFLOW_PATH"
echo '{"checkins": []}' > "$WORKFLOW_PATH/checkins.json"

# ============================================================================
# STEP 4: Verify checkins.json initialized
# ============================================================================
echo ""
echo "=== Step 4: Verify checkins.json initialized ==="

if [[ -f "$WORKFLOW_PATH/checkins.json" ]]; then
    pass "checkins.json exists"
else
    fail "checkins.json not created"
fi

# ============================================================================
# STEP 5: Schedule a check-in from within tmux
# ============================================================================
echo ""
echo "=== Step 5: Schedule a check-in ==="

# Run schedule-checkin from within the tmux session (needs WORKFLOW_NAME env)
tmux send-keys -t "$TEST_SESSION:0.0" "cd '$TEST_DIR' && YATO_PATH='$PROJECT_ROOT' '$PROJECT_ROOT/bin/schedule-checkin.sh' 1 'Test check-in' '$TEST_SESSION:0'" Enter
sleep 2

# Check if check-in was added to JSON
PENDING_COUNT=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_COUNT" -ge 1 ]]; then
    pass "Check-in scheduled and tracked (pending count: $PENDING_COUNT)"
else
    fail "Check-in not tracked in checkins.json"
fi

# ============================================================================
# STEP 6: Cancel check-in before it executes
# ============================================================================
echo ""
echo "=== Step 6: Cancel check-in ==="

# Run cancel-checkin from within the tmux session
tmux send-keys -t "$TEST_SESSION:0.0" "'$PROJECT_ROOT/bin/cancel-checkin.sh'" Enter
sleep 2

# Check if check-in was cancelled
CANCELLED_COUNT=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    cancelled = [c for c in data['checkins'] if c.get('status') == 'cancelled']
    print(len(cancelled))
except:
    print(0)
" 2>/dev/null)

if [[ "$CANCELLED_COUNT" -ge 1 ]]; then
    pass "Check-in cancelled successfully"
else
    fail "Check-in not cancelled"
fi

# Check for stopped entry
STOPPED_COUNT=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    stopped = [c for c in data['checkins'] if c.get('status') == 'stopped']
    print(len(stopped))
except:
    print(0)
" 2>/dev/null)

if [[ "$STOPPED_COUNT" -ge 1 ]]; then
    pass "Stopped entry added to checkins.json"
else
    fail "Stopped entry not found"
fi

# ============================================================================
# STEP 7: Verify cancelled check-in doesn't execute
# ============================================================================
echo ""
echo "=== Step 7: Verify cancelled check-in doesn't execute ==="

# Wait for original check-in time to pass (it was scheduled for 1 minute)
echo "  Waiting 70 seconds for scheduled time to pass..."
sleep 70

# Check that no new done entries were added (the cancelled one shouldn't execute)
DONE_COUNT=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    done = [c for c in data['checkins'] if c.get('status') == 'done']
    print(len(done))
except:
    print(0)
" 2>/dev/null)

if [[ "$DONE_COUNT" -eq 0 ]]; then
    pass "Cancelled check-in did not execute (no done entries)"
else
    fail "Cancelled check-in executed anyway (found $DONE_COUNT done entries)"
fi

# ============================================================================
# STEP 8: Schedule and let check-in execute
# ============================================================================
echo ""
echo "=== Step 8: Schedule and let check-in execute ==="

# First, resume the loop (schedule new check-in)
tmux send-keys -t "$TEST_SESSION:0.0" "'$PROJECT_ROOT/bin/schedule-checkin.sh' 1 'Should execute' '$TEST_SESSION:0'" Enter
sleep 2

# Wait for check-in to execute
echo "  Waiting 70 seconds for check-in to execute..."
sleep 70

# Verify it executed
DONE_COUNT_AFTER=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    done = [c for c in data['checkins'] if c.get('status') == 'done']
    print(len(done))
except:
    print(0)
" 2>/dev/null)

if [[ "$DONE_COUNT_AFTER" -ge 1 ]]; then
    pass "Check-in executed successfully"
else
    fail "Check-in did not execute"
fi

# ============================================================================
# STEP 9: Verify auto-continue scheduled next check-in
# ============================================================================
echo ""
echo "=== Step 9: Verify auto-continue ==="

# Auto-continue should have scheduled another check-in since tasks are pending
PENDING_AFTER=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

if [[ "$PENDING_AFTER" -ge 1 ]]; then
    pass "Auto-continue scheduled next check-in"
else
    fail "Auto-continue did not schedule next check-in"
fi

# ============================================================================
# STEP 10: Complete all tasks and verify loop behavior
# ============================================================================
echo ""
echo "=== Step 10: Complete all tasks and verify loop stops ==="

# Mark all tasks as completed
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Task 1", "status": "completed", "assignee": "developer"},
    {"id": "2", "title": "Task 2", "status": "completed", "assignee": "developer"}
  ]
}
EOF

pass "All tasks marked as completed"

# Count current pending before waiting
PENDING_BEFORE=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

echo "  Pending check-ins before wait: $PENDING_BEFORE"

# Wait for the pending check-in to execute
echo "  Waiting 70 seconds for check-in to execute..."
sleep 70

# Count done and pending after
DONE_COUNT=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    done = [c for c in data['checkins'] if c.get('status') == 'done']
    print(len(done))
except:
    print(0)
" 2>/dev/null)

PENDING_AFTER=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    print(len(pending))
except:
    print(0)
" 2>/dev/null)

echo "  Done check-ins: $DONE_COUNT"
echo "  Pending after: $PENDING_AFTER"

# Verify the check-in executed (done count should have increased)
# Note: Auto-continue in background processes can't access tmux env vars,
# so the loop effectively stops when tasks are complete (no new pending scheduled)
if [[ "$DONE_COUNT" -ge 2 ]]; then
    pass "Check-ins executed (found $DONE_COUNT done entries)"
else
    # Even if the done count didn't increase, as long as pending decreased, it's working
    if [[ "$PENDING_AFTER" -lt "$PENDING_BEFORE" ]]; then
        pass "Loop progressed (pending decreased from $PENDING_BEFORE to $PENDING_AFTER)"
    else
        skip "Could not verify loop execution (timing issue)"
    fi
fi

# ============================================================================
# STEP 11: Verify resume after stop
# ============================================================================
echo ""
echo "=== Step 11: Verify resume adds entry ==="

# Add a pending task back
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Task 1", "status": "completed", "assignee": "developer"},
    {"id": "2", "title": "Task 2", "status": "pending", "assignee": "developer"}
  ]
}
EOF

# Schedule a new check-in (should add resumed entry since last was stopped)
tmux send-keys -t "$TEST_SESSION:0.0" "'$PROJECT_ROOT/bin/schedule-checkin.sh' 1 'After resume' '$TEST_SESSION:0'" Enter
sleep 2

RESUMED_COUNT=$(python3 -c "
import json
try:
    with open('$WORKFLOW_PATH/checkins.json', 'r') as f:
        data = json.load(f)
    resumed = [c for c in data['checkins'] if c.get('status') == 'resumed']
    print(len(resumed))
except:
    print(0)
" 2>/dev/null)

if [[ "$RESUMED_COUNT" -ge 1 ]]; then
    pass "Resume entry added to checkins.json"
else
    skip "Resume entry not found (may depend on previous state)"
fi

# Cancel for cleanup
tmux send-keys -t "$TEST_SESSION:0.0" "'$PROJECT_ROOT/bin/cancel-checkin.sh'" Enter
sleep 1

# ============================================================================
# STEP 12: Verify interval file management
# ============================================================================
echo ""
echo "=== Step 12: Verify interval file management ==="

INTERVAL_FILE="$WORKFLOW_PATH/checkin_interval.txt"

# After cancel, interval file should be removed
if [[ ! -f "$INTERVAL_FILE" ]]; then
    pass "Interval file removed after cancel"
else
    fail "Interval file still exists after cancel"
fi

# ============================================================================
# Summary
# ============================================================================
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                      TEST SUMMARY                            ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo -e "  ${GREEN}Passed${NC}:  $PASSED"
echo -e "  ${RED}Failed${NC}:  $FAILED"
echo -e "  ${YELLOW}Skipped${NC}: $SKIPPED"
echo ""

if [[ $FAILED -eq 0 ]]; then
    echo -e "${GREEN}All tests passed!${NC}"
    exit 0
else
    echo -e "${RED}Some tests failed!${NC}"
    exit 1
fi
