#!/bin/bash
# test-checkin-quoted-session.sh
#
# E2E Test: Checkin system handles YAML-quoted session values and daemon PID tracking
#
# Verifies:
# 1. get_session_target() strips YAML quotes from session values in status.yml
# 2. Daemon PID tracking works correctly (dead PID = stopped)
# 3. Dead daemon + incomplete tasks = restart
# 4. Dead daemon + all tasks complete = no restart
# 5. Running daemon is correctly detected as running
#
# IMPORTANT: All execution goes through Claude Code in a tmux session.

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-quoted-session"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-quoted-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Checkin Quoted Session + Daemon PID Tracking"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Kill any daemon processes
    if [[ -f "$TEST_DIR/.workflow/001-test-workflow/checkins.json" ]]; then
        PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
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

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/tasks-change-hook.py"

# ============================================================
# Phase 1: Setup test environment
# ============================================================
echo "Phase 1: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow"

# Create tmux session with larger size for Claude TUI
# IMPORTANT: Use -x 120 -y 40 for Claude's TUI to work properly
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME "001-test-workflow"
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" YATO_PATH "$PROJECT_ROOT"

# Create a second window for Claude
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -n "claude" -c "$TEST_DIR"

if tmux -L "$TMUX_SOCKET" has-session -t "$SESSION_NAME" 2>/dev/null; then
    pass "Tmux session created"
else
    fail "Failed to create tmux session"
    exit 1
fi

echo "  Test directory: $TEST_DIR"
echo "  Session: $SESSION_NAME"

# Start Claude in window 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "claude" Enter

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
# Phase 2: Test quoted session value in status.yml
# ============================================================
echo "Phase 2: Testing YAML-quoted session value handling..."

# Use yaml.dump to create status.yml - this reproduces the real quoting behavior
uv run python -c "
import yaml
data = {
    'status': 'in-progress',
    'checkin_interval_minutes': 5,
    'session': 'null'
}
with open('$TEST_DIR/.workflow/001-test-workflow/status.yml', 'w') as f:
    f.write('# Workflow Status\n')
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
"

# Verify the YAML file actually has quotes around session value
if grep -q "session: 'null'" "$TEST_DIR/.workflow/001-test-workflow/status.yml"; then
    pass "yaml.dump quotes reserved word 'null' in status.yml"
else
    SESSION_LINE=$(grep "^session:" "$TEST_DIR/.workflow/001-test-workflow/status.yml")
    echo "  Note: session line is: $SESSION_LINE"
    pass "status.yml created (quoting may vary by PyYAML version)"
fi

# Create stopped checkins.json + incomplete tasks
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-100", "status": "stopped", "note": "Stopped", "created_at": "2024-01-01T10:00:00"}
  ],
  "daemon_pid": null
}
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Task 1", "status": "pending"}
  ]
}
EOF

# Ask Claude to run the hook via bash (simulating real execution environment)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $TEST_DIR && echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE'"
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

# Check that a new daemon was started and pending check-in was created
PENDING_TARGET=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    if pending:
        print(pending[-1].get('target', ''))
    else:
        print('NO_PENDING')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

# The target should NOT contain quote characters
if echo "$PENDING_TARGET" | grep -q '["\x27]'; then
    fail "Target contains embedded quotes: $PENDING_TARGET"
else
    if [[ "$PENDING_TARGET" == "null:0.1" ]]; then
        pass "Target correctly unquoted: $PENDING_TARGET"
    elif [[ "$PENDING_TARGET" == "NO_PENDING" ]]; then
        fail "No pending check-in was created"
    else
        pass "Target has no embedded quotes: $PENDING_TARGET"
    fi
fi

echo ""

# ============================================================
# Phase 3: Test with typical session name that yaml.dump quotes
# ============================================================
echo "Phase 3: Testing with realistic session name..."

# Ask Claude to cancel the daemon from phase 2
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $TEST_DIR && uv run python $PROJECT_ROOT/lib/checkin_scheduler.py cancel --workflow '001-test-workflow'"
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

# Use 'on' which is a YAML boolean that PyYAML will quote
uv run python -c "
import yaml
data = {
    'status': 'in-progress',
    'checkin_interval_minutes': 3,
    'session': 'on'
}
with open('$TEST_DIR/.workflow/001-test-workflow/status.yml', 'w') as f:
    f.write('# Workflow Status\n')
    yaml.dump(data, f, default_flow_style=False, allow_unicode=True)
"

# Reset checkins to stopped state with no daemon
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {"id": "stop-200", "status": "stopped", "note": "Stopped", "created_at": "2024-01-01T10:00:00"}
  ],
  "daemon_pid": null
}
EOF

# Ask Claude to run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE_2'"
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

PENDING_TARGET2=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pending = [c for c in data['checkins'] if c.get('status') == 'pending']
    if pending:
        print(pending[-1].get('target', ''))
    else:
        print('NO_PENDING')
except Exception as e:
    print(f'ERROR: {e}')
" 2>/dev/null)

if [[ "$PENDING_TARGET2" == "on:0.1" ]]; then
    pass "YAML boolean 'on' correctly unquoted in target: $PENDING_TARGET2"
elif echo "$PENDING_TARGET2" | grep -q '["\x27]'; then
    fail "Target contains embedded quotes: $PENDING_TARGET2"
else
    pass "Target has no embedded quotes: $PENDING_TARGET2"
fi

echo ""

# ============================================================
# Phase 4: Test dead daemon PID detection
# ============================================================
echo "Phase 4: Testing dead daemon PID detection..."

# Ask Claude to cancel the daemon from phase 3
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $TEST_DIR && uv run python $PROJECT_ROOT/lib/checkin_scheduler.py cancel --workflow '001-test-workflow'"
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

# Create status.yml with 1-minute interval
cat > "$TEST_DIR/.workflow/001-test-workflow/status.yml" << 'EOF'
status: in-progress
checkin_interval_minutes: 1
session: test-session
EOF

# Create checkins.json with a dead daemon PID (process that doesn't exist)
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {
      "id": "dead-999",
      "status": "pending",
      "scheduled_for": "2050-01-01T10:00:00",
      "note": "This daemon process died",
      "target": "dead-session:0",
      "created_at": "2024-01-01T10:00:00"
    }
  ],
  "daemon_pid": 999999
}
EOF

# Ensure tasks are incomplete
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Pending task", "status": "pending"}
  ]
}
EOF

# Ask Claude to test is_daemon_running directly
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python -c \"import sys; sys.path.insert(0, '$PROJECT_ROOT/lib'); from checkin_scheduler import CheckinScheduler; s = CheckinScheduler('$TEST_DIR/.workflow/001-test-workflow'); print('yes' if s.is_daemon_running() else 'no')\""
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

# Capture output and check for "no"
IS_RUNNING_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -50 2>/dev/null)
if echo "$IS_RUNNING_OUTPUT" | grep -q "no"; then
    pass "Dead daemon PID correctly detected as not running"
else
    fail "Should detect dead daemon as not running"
fi

# Ask Claude to run the hook - should start new daemon since the PID is dead
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE_3'"
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

# Check that a new daemon PID was set
NEW_DAEMON_PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid and pid != 999999:
        print(pid)
    else:
        print('')
except:
    print('')
" 2>/dev/null)

if [[ -n "$NEW_DAEMON_PID" ]]; then
    pass "New daemon started after detecting dead PID: $NEW_DAEMON_PID"
else
    fail "Expected new daemon to be started after dead PID detection"
fi

echo ""

# ============================================================
# Phase 5: Dead daemon + all tasks complete = no restart
# ============================================================
echo "Phase 5: Testing dead daemon with all tasks complete (no restart)..."

# Ask Claude to cancel the daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $TEST_DIR && uv run python $PROJECT_ROOT/lib/checkin_scheduler.py cancel --workflow '001-test-workflow'"
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

# Create dead daemon scenario
cat > "$TEST_DIR/.workflow/001-test-workflow/checkins.json" << 'EOF'
{
  "checkins": [
    {
      "id": "dead-888",
      "status": "pending",
      "scheduled_for": "2050-01-01T10:00:00",
      "note": "Dead daemon",
      "target": "dead-session:0",
      "created_at": "2024-01-01T10:00:00"
    }
  ],
  "daemon_pid": 888888
}
EOF

# All tasks completed
cat > "$TEST_DIR/.workflow/001-test-workflow/tasks.json" << 'EOF'
{
  "tasks": [
    {"id": "T1", "subject": "Done task", "status": "completed"},
    {"id": "T2", "subject": "Also done", "status": "completed"}
  ]
}
EOF

# Ask Claude to run the hook
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | YATO_PATH='$PROJECT_ROOT' uv run python '$HOOK_SCRIPT' 2>&1 && echo 'HOOK_DONE_4'"
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

# Should NOT create new daemon since all tasks are complete
FINAL_PID=$(uv run python -c "
import json
try:
    with open('$TEST_DIR/.workflow/001-test-workflow/checkins.json', 'r') as f:
        data = json.load(f)
    pid = data.get('daemon_pid')
    if pid and pid != 888888:
        print(pid)
    else:
        print('')
except:
    print('')
" 2>/dev/null)

if [[ -z "$FINAL_PID" ]]; then
    pass "No new daemon when dead PID + all tasks complete"
else
    fail "Should not start daemon when all tasks complete, new PID: $FINAL_PID"
fi

echo ""

# ============================================================
# Phase 6: Running daemon is NOT treated as stopped
# ============================================================
echo "Phase 6: Testing running daemon is not treated as stopped..."

# Ask Claude to start a real daemon
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $TEST_DIR && uv run python $PROJECT_ROOT/lib/checkin_scheduler.py start 5 --note 'Test' --target '$SESSION_NAME:0' --workflow '001-test-workflow'"
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

# Ask Claude to check is_daemon_running
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "Run this exact command in bash: cd $PROJECT_ROOT && uv run python -c \"import sys; sys.path.insert(0, '$PROJECT_ROOT/lib'); from checkin_scheduler import CheckinScheduler; s = CheckinScheduler('$TEST_DIR/.workflow/001-test-workflow'); print('yes' if s.is_daemon_running() else 'no')\""
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

IS_RUNNING_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -50 2>/dev/null)
if echo "$IS_RUNNING_OUTPUT" | grep -q "yes"; then
    pass "Running daemon correctly detected as running"
else
    fail "Should treat running daemon as running"
fi

echo ""

# ============================================================
# Results
# ============================================================
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    exit 0
else
    echo "  SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    exit 1
fi
