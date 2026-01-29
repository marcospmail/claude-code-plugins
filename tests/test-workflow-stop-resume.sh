#!/bin/bash
# E2E Test: Full workflow - stop and resume session
# Simulates user stopping work (closing terminal) and resuming later
# Run: ./tests/test-workflow-stop-resume.sh

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TEST_DIR="/tmp/stopres$$"
TEST_SESSION="stopres$$"

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
echo "║   E2E Test: Stop and Resume Workflow (Like Closing Browser) ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Scenario: User works on project, closes terminal, comes back later"
echo ""

# ============================================================================
# STEP 1: User creates and starts a project
# ============================================================================
echo "=== Step 1: User creates project and workflow ==="
mkdir -p "$TEST_DIR"

"$PROJECT_ROOT/bin/init-workflow.sh" "$TEST_DIR" "Build REST API with Express" > /dev/null 2>&1

WORKFLOW_NAME=$(ls "$TEST_DIR/.workflow" | grep -E "^[0-9]{3}-" | head -1)
WORKFLOW_PATH="$TEST_DIR/.workflow/$WORKFLOW_NAME"

if [[ -n "$WORKFLOW_NAME" ]]; then
    pass "Workflow created: $WORKFLOW_NAME"
else
    fail "Workflow not created"
    exit 1
fi

# ============================================================================
# STEP 2: User sets up team and tasks
# ============================================================================
echo ""
echo "=== Step 2: User sets up team and tasks ==="

# Create tasks
cat > "$WORKFLOW_PATH/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "1", "title": "Set up Express server", "status": "completed", "assignee": "developer"},
    {"id": "2", "title": "Create user routes", "status": "in_progress", "assignee": "developer"},
    {"id": "3", "title": "Add authentication", "status": "pending", "assignee": "developer"},
    {"id": "4", "title": "Write API tests", "status": "pending", "assignee": "qa"}
  ]
}
EOF

# Create team
cat > "$WORKFLOW_PATH/agents.yml" << EOF
# Agent Registry
pm:
  name: pm
  role: pm
  session: "$TEST_SESSION"
  window: 0
  pane: 1
  model: opus

agents:
  - name: backend-dev
    role: developer
    session: "$TEST_SESSION"
    window: 1
    model: sonnet
  - name: api-tester
    role: qa
    session: "$TEST_SESSION"
    window: 2
    model: haiku
EOF

mkdir -p "$WORKFLOW_PATH/agents/developer" "$WORKFLOW_PATH/agents/qa"
echo "# Backend Dev" > "$WORKFLOW_PATH/agents/developer/instructions.md"
echo "# API Tester" > "$WORKFLOW_PATH/agents/qa/instructions.md"

pass "Team and tasks configured"

# ============================================================================
# STEP 3: User starts initial session
# ============================================================================
echo ""
echo "=== Step 3: User starts initial workflow session ==="

RESUME_OUT=$("$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" 2>&1)

if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Initial session started"
else
    fail "Initial session not created"
fi

# Record initial window indices
INITIAL_WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}" 2>/dev/null)
echo "  Initial windows: $INITIAL_WINDOWS"

# ============================================================================
# STEP 4: User "closes terminal" (kills session)
# ============================================================================
echo ""
echo "=== Step 4: User closes terminal (session killed) ==="

tmux kill-session -t "$TEST_SESSION" 2>/dev/null

if ! tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Session killed (simulating closed terminal)"
else
    fail "Session still exists"
fi

# Small delay to simulate time passing
sleep 1

# ============================================================================
# STEP 5: User comes back and resumes workflow
# ============================================================================
echo ""
echo "=== Step 5: User comes back and resumes workflow ==="

RESUME_OUT2=$("$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" 2>&1)

if echo "$RESUME_OUT2" | grep -q "WORKFLOW RESUMED SUCCESSFULLY"; then
    pass "Workflow resumed successfully"
else
    fail "Workflow resume failed"
    echo "$RESUME_OUT2"
fi

# ============================================================================
# STEP 6: User verifies session restored
# ============================================================================
echo ""
echo "=== Step 6: User verifies session restored ==="

if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    pass "Session restored"
else
    fail "Session not restored"
fi

# ============================================================================
# STEP 7: User verifies all windows restored
# ============================================================================
echo ""
echo "=== Step 7: User verifies all windows restored ==="

RESTORED_WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_index}:#{window_name}" 2>/dev/null)
echo "  Restored windows: $RESTORED_WINDOWS"

# Check for expected windows
if echo "$RESTORED_WINDOWS" | grep -q "backend-dev"; then
    pass "Developer window restored"
else
    fail "Developer window missing"
fi

if echo "$RESTORED_WINDOWS" | grep -q "api-tester"; then
    pass "QA window restored"
else
    fail "QA window missing"
fi

# ============================================================================
# STEP 8: User verifies agents.yml updated
# ============================================================================
echo ""
echo "=== Step 8: User verifies agents.yml updated with new windows ==="

# Read current window numbers from agents.yml
DEV_WINDOW=$(grep -A5 "name: backend-dev" "$WORKFLOW_PATH/agents.yml" | grep "window:" | awk '{print $2}')
QA_WINDOW=$(grep -A5 "name: api-tester" "$WORKFLOW_PATH/agents.yml" | grep "window:" | awk '{print $2}')

echo "  backend-dev window: $DEV_WINDOW"
echo "  api-tester window: $QA_WINDOW"

if [[ -n "$DEV_WINDOW" ]] && [[ -n "$QA_WINDOW" ]]; then
    pass "agents.yml has window numbers"
else
    fail "agents.yml missing window numbers"
fi

# ============================================================================
# STEP 9: User verifies Claude running in restored windows
# ============================================================================
echo ""
echo "=== Step 9: User verifies Claude running in agents ==="
sleep 3

CLAUDE_FOUND=0
for window in $DEV_WINDOW $QA_WINDOW; do
    CONTENT=$(tmux capture-pane -t "$TEST_SESSION:$window" -p 2>/dev/null | tail -10)
    if echo "$CONTENT" | grep -qi "claude\|bypass\|anthropic"; then
        CLAUDE_FOUND=$((CLAUDE_FOUND + 1))
    fi
done

if [[ "$CLAUDE_FOUND" -ge 1 ]]; then
    pass "Claude running in $CLAUDE_FOUND restored windows"
else
    skip "Could not verify Claude (may need more startup time)"
fi

# ============================================================================
# STEP 10: User verifies tasks still intact
# ============================================================================
echo ""
echo "=== Step 10: User verifies tasks.json preserved ==="

COMPLETED_COUNT=$(python3 -c "
import json
with open('$WORKFLOW_PATH/tasks.json') as f:
    data = json.load(f)
print(len([t for t in data['tasks'] if t['status'] == 'completed']))
" 2>/dev/null)

IN_PROGRESS_COUNT=$(python3 -c "
import json
with open('$WORKFLOW_PATH/tasks.json') as f:
    data = json.load(f)
print(len([t for t in data['tasks'] if t['status'] == 'in_progress']))
" 2>/dev/null)

if [[ "$COMPLETED_COUNT" == "1" ]] && [[ "$IN_PROGRESS_COUNT" == "1" ]]; then
    pass "Task statuses preserved (1 completed, 1 in_progress)"
else
    fail "Task statuses changed"
fi

# ============================================================================
# STEP 11: Stop and resume again to test multiple cycles
# ============================================================================
echo ""
echo "=== Step 11: User stops and resumes again (multiple cycles) ==="

tmux kill-session -t "$TEST_SESSION" 2>/dev/null
sleep 1

RESUME_OUT3=$("$PROJECT_ROOT/bin/resume-workflow.sh" "$TEST_DIR" "$WORKFLOW_NAME" 2>&1)

if tmux has-session -t "$TEST_SESSION" 2>/dev/null; then
    FINAL_WINDOWS=$(tmux list-windows -t "$TEST_SESSION" -F "#{window_name}" 2>/dev/null)
    if echo "$FINAL_WINDOWS" | grep -q "backend-dev" && echo "$FINAL_WINDOWS" | grep -q "api-tester"; then
        pass "Multiple stop/resume cycles work correctly"
    else
        fail "Windows missing after multiple cycles"
    fi
else
    fail "Session not created after second resume"
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
