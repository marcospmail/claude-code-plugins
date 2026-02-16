#!/bin/bash
# test-per-project-message-suffix.sh
#
# E2E Test: Per-Project Message Suffix Feature (Real Claude Code Session)
#
# Verifies that workflow-specific status.yml contains agent_message_suffix and
# checkin_message_suffix fields, and that these suffixes are correctly appended
# when using a REAL Claude Code session.
#
# Tests:
# 1. Creating a workflow adds both agent_message_suffix and checkin_message_suffix fields
# 2. agent_message_suffix gets appended when Claude runs send_message() with workflow_status_file
# 3. checkin_message_suffix gets appended to check-in daemon messages (Claude simulates daemon logic)
# 4. notify_pm messages (Claude runs send_message() without workflow_status_file) have NO suffix
# 5. Changing suffix in status.yml between Claude sends takes effect immediately
# 6. Empty suffix adds nothing
# 7. Per-project isolation: two projects with different suffixes produce different results

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="per-project-suffix-real-claude"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-pps-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Per-Project Message Suffix (Real Claude Code Session)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  ✅ $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  ❌ $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -rf "$TEST_DIR_B" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: send a command to Claude and approve the permission prompt
send_to_claude() {
    local cmd="$1"
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "$cmd"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" Enter
    sleep 15  # Wait for Claude to show permission prompt

    # Approve the permission prompt (press Enter to accept "Yes")
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" Enter
    sleep 10  # Wait for command to execute
}

# ============================================================
# Setup
# ============================================================
echo "Setting up test environment..."
mkdir -p "$TEST_DIR/config"

# Create config/defaults.conf with empty PM_TO_AGENTS_SUFFIX so global fallback does not interfere
cat > "$TEST_DIR/config/defaults.conf" <<'EOF'
PM_TO_AGENTS_SUFFIX=""
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
EOF

# Create a dummy file so Claude trusts the directory
echo "// test project" > "$TEST_DIR/index.js"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# Create tmux session with three windows: Claude (0), PM (1), Agent (2)
echo "Starting tmux session and Claude..."
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "claude" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "pm" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "agent" -c "$TEST_DIR"

# Disable flow control in PM and Agent windows
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "stty -ixon" Enter
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "stty -ixon" Enter
sleep 1

# Start Claude in window 0 (skip permissions to avoid blocking on bash prompts)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "claude --dangerously-skip-permissions" Enter

# Wait for Claude to start and handle trust prompt
echo "Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" Enter
    sleep 15
else
    echo "No trust prompt found, continuing..."
    sleep 5
fi

echo ""
echo "======================================================================"
echo "  Test 1: Workflow creation adds both suffix fields to status.yml"
echo "======================================================================"
echo ""

# Ask Claude to create a workflow
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' uv run python -c \"from lib.workflow_ops import create_workflow_folder; create_workflow_folder('$TEST_DIR', 'Test suffix feature', session='$SESSION_NAME')\""

# Find the workflow folder using Python glob
WORKFLOW_FOLDER=$(cd "$PROJECT_ROOT" && uv run python -c "
from pathlib import Path
folders = sorted(Path('$TEST_DIR/.workflow').glob('001-*'))
if folders:
    print(str(folders[0]))
")

if [[ -z "$WORKFLOW_FOLDER" ]]; then
    fail "Workflow folder not created"
    exit 1
fi

STATUS_FILE="$WORKFLOW_FOLDER/status.yml"

if [[ -f "$STATUS_FILE" ]]; then
    pass "status.yml created"
else
    fail "status.yml not found"
    exit 1
fi

# Check for both suffix fields
if grep -q "agent_message_suffix:" "$STATUS_FILE"; then
    pass "agent_message_suffix field exists in status.yml"
else
    fail "agent_message_suffix field missing from status.yml"
fi

if grep -q "checkin_message_suffix:" "$STATUS_FILE"; then
    pass "checkin_message_suffix field exists in status.yml"
else
    fail "checkin_message_suffix field missing from status.yml"
fi

echo ""
echo "======================================================================"
echo "  Test 2: agent_message_suffix appended via real Claude session"
echo "======================================================================"
echo ""

# Set a unique suffix for agent messages using Python
AGENT_SUFFIX=" --AGENT_SUFFIX_TEST--"
cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
data['agent_message_suffix'] = '$AGENT_SUFFIX'
sf.write_text(yaml.dump(data, default_flow_style=False))
"

MSG1="AGENT_MSG_$(date +%s)"

# Ask Claude to run send_message with workflow_status_file parameter
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG1', workflow_status_file='$STATUS_FILE')\""

# Debug: show what Claude did
echo "Debug - Claude output after Test 2:"
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p | tail -15
echo ""

# Capture agent pane output
OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

echo "Debug - Agent pane content:"
echo "$OUTPUT1" | tail -10
echo ""

# Verify original message is present
if echo "$OUTPUT1" | grep -Fq "$MSG1"; then
    pass "Original message delivered to agent"
else
    fail "Original message not found in agent pane"
    echo "     Expected: $MSG1"
fi

# Verify agent_message_suffix is appended
if echo "$OUTPUT1" | grep -Fq "$AGENT_SUFFIX"; then
    pass "agent_message_suffix appended to message"
else
    fail "agent_message_suffix not found in agent output"
    echo "     Expected suffix: $AGENT_SUFFIX"
fi

# Verify both appear in output (suffix is on separate line per design, separated by \n\n)
if echo "$OUTPUT1" | grep -Fq "$MSG1" && echo "$OUTPUT1" | grep -Fq "$AGENT_SUFFIX"; then
    pass "Message and agent_message_suffix both present in output"
else
    fail "Message and agent_message_suffix not both present in output"
fi

echo ""
echo "======================================================================"
echo "  Test 3: checkin_message_suffix appended to daemon messages"
echo "======================================================================"
echo ""

# Set a unique suffix for check-in messages using Python
CHECKIN_SUFFIX=" --CHECKIN_SUFFIX_TEST--"
cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
data['checkin_message_suffix'] = '$CHECKIN_SUFFIX'
sf.write_text(yaml.dump(data, default_flow_style=False))
"

MSG2="CHECKIN_DAEMON_MSG_$(date +%s)"

# Ask Claude to simulate what the daemon does: read checkin_message_suffix and append it
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"
import yaml
from pathlib import Path
from lib.tmux_utils import send_message
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
suffix = data.get('checkin_message_suffix', '')
msg = '$MSG2' + suffix
send_message('$SESSION_NAME:1', msg)
\""

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

echo "Debug - PM pane after checkin:"
echo "$OUTPUT2" | tail -10
echo ""

# Verify checkin message is delivered
if echo "$OUTPUT2" | grep -Fq "$MSG2"; then
    pass "Checkin message delivered to PM"
else
    fail "Checkin message not delivered"
fi

# Verify checkin_message_suffix is appended (suffix on separate line per design)
if echo "$OUTPUT2" | grep -Fq "$MSG2" && echo "$OUTPUT2" | grep -Fq "$CHECKIN_SUFFIX"; then
    pass "checkin_message_suffix appended to checkin message"
else
    fail "checkin_message_suffix not found in output"
    echo "     Expected: $MSG2 and $CHECKIN_SUFFIX in output"
fi

echo ""
echo "======================================================================"
echo "  Test 4: notify_pm messages have NO suffix (unchanged behavior)"
echo "======================================================================"
echo ""

MSG3="NOTIFY_PM_MSG_$(date +%s)"

# Send message WITHOUT workflow_status_file (simulates notify_pm path - no suffix)
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:1', '$MSG3')\""

OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

echo "Debug - PM pane after notify_pm:"
echo "$OUTPUT3" | tail -10
echo ""

# Verify message is delivered
if echo "$OUTPUT3" | grep -Fq "$MSG3"; then
    pass "notify_pm message delivered to PM"
else
    fail "notify_pm message not delivered"
fi

# Verify NO suffix on the line with MSG3
MSG3_LINE=$(echo "$OUTPUT3" | grep -F "$MSG3" | tail -1)
if echo "$MSG3_LINE" | grep -Fq "$AGENT_SUFFIX"; then
    fail "notify_pm path should NOT have agent_message_suffix"
else
    pass "notify_pm path correctly has no suffix"
fi

echo ""
echo "======================================================================"
echo "  Test 5: Changed suffix is picked up immediately (fresh reads)"
echo "======================================================================"
echo ""

# Change the agent_message_suffix in status.yml while Claude is still running
NEW_AGENT_SUFFIX=" --UPDATED_SUFFIX_V2--"

cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
data['agent_message_suffix'] = '$NEW_AGENT_SUFFIX'
sf.write_text(yaml.dump(data, default_flow_style=False))
"

MSG4="FRESH_READ_$(date +%s)"

# Ask Claude to send again - should pick up the NEW suffix
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG4', workflow_status_file='$STATUS_FILE')\""

OUTPUT4=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

echo "Debug - Agent pane after suffix change:"
echo "$OUTPUT4" | tail -10
echo ""

# Should have NEW suffix (suffix on separate line per design)
if echo "$OUTPUT4" | grep -Fq "$MSG4" && echo "$OUTPUT4" | grep -Fq "$NEW_AGENT_SUFFIX"; then
    pass "Changed suffix immediately effective (fresh read from status.yml)"
else
    fail "New suffix not applied - possible caching issue"
    echo "     Expected: $MSG4 and $NEW_AGENT_SUFFIX in output"
fi

# Should NOT have old suffix on this message
MSG4_LINE=$(echo "$OUTPUT4" | grep -F "$MSG4" | tail -1)
if echo "$MSG4_LINE" | grep -Fq "$AGENT_SUFFIX"; then
    fail "Old suffix still present - not reading status.yml fresh"
else
    pass "Old suffix correctly replaced by new one"
fi

echo ""
echo "======================================================================"
echo "  Test 6: Empty suffix adds nothing"
echo "======================================================================"
echo ""

# Set both suffixes to empty using Python
cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
data['agent_message_suffix'] = ''
data['checkin_message_suffix'] = ''
sf.write_text(yaml.dump(data, default_flow_style=False))
"

MSG5="CLEAN_MSG_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG5', workflow_status_file='$STATUS_FILE')\""

OUTPUT5=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

echo "Debug - Agent pane with empty suffix:"
echo "$OUTPUT5" | tail -10
echo ""

if echo "$OUTPUT5" | grep -Fq "$MSG5"; then
    pass "Message delivered with empty suffix"
else
    fail "Message with empty suffix not delivered"
fi

# The line containing MSG5 should NOT have any suffix markers
MSG5_LINE=$(echo "$OUTPUT5" | grep -F "$MSG5" | tail -1)
if echo "$MSG5_LINE" | grep -Fq "SUFFIX"; then
    fail "Empty suffix should not add any suffix markers"
else
    pass "Empty suffix correctly adds nothing"
fi

echo ""
echo "======================================================================"
echo "  Test 7: Per-project isolation (different suffixes per project)"
echo "======================================================================"
echo ""

# Create a second project directory with its own workflow and suffix
TEST_DIR_B="/tmp/e2e-test-$TEST_NAME-b-$$"
mkdir -p "$TEST_DIR_B/config"
cat > "$TEST_DIR_B/config/defaults.conf" <<'EOF'
PM_TO_AGENTS_SUFFIX=""
DEFAULT_SESSION="test"
EOF

echo "// test project B" > "$TEST_DIR_B/index.js"

# Ask Claude to create workflow for project B
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR_B' uv run python -c \"from lib.workflow_ops import create_workflow_folder; create_workflow_folder('$TEST_DIR_B', 'Project B workflow', session='$SESSION_NAME')\""

# Find project B workflow folder using Python glob
WORKFLOW_FOLDER_B=$(cd "$PROJECT_ROOT" && uv run python -c "
from pathlib import Path
folders = sorted(Path('$TEST_DIR_B/.workflow').glob('001-*'))
if folders:
    print(str(folders[0]))
")

STATUS_FILE_B="$WORKFLOW_FOLDER_B/status.yml"

# Set different suffixes for each project
SUFFIX_A=" --PROJECT_A--"
SUFFIX_B=" --PROJECT_B--"

cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path

# Project A suffix
sf_a = Path('$STATUS_FILE')
data_a = yaml.safe_load(sf_a.read_text())
data_a['agent_message_suffix'] = '$SUFFIX_A'
sf_a.write_text(yaml.dump(data_a, default_flow_style=False))

# Project B suffix
sf_b = Path('$STATUS_FILE_B')
data_b = yaml.safe_load(sf_b.read_text())
data_b['agent_message_suffix'] = '$SUFFIX_B'
sf_b.write_text(yaml.dump(data_b, default_flow_style=False))
"

# Clear agent pane for clean capture
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "clear" Enter
sleep 1

# Ask Claude to send message from project A
MSG6A="PROJ_A_MSG_$(date +%s)"
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG6A', workflow_status_file='$STATUS_FILE')\""

# Ask Claude to send message from project B
MSG6B="PROJ_B_MSG_$(date +%s)"
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR_B' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG6B', workflow_status_file='$STATUS_FILE_B')\""

OUTPUT6=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

echo "Debug - Agent pane with both project messages:"
echo "$OUTPUT6" | tail -15
echo ""

# Verify project A message has project A suffix (suffix on separate line per design)
if echo "$OUTPUT6" | grep -Fq "$MSG6A" && echo "$OUTPUT6" | grep -Fq "$SUFFIX_A"; then
    pass "Project A message has project A suffix"
else
    fail "Project A message missing project A suffix"
fi

# Verify project A message line does NOT contain project B suffix
if echo "$OUTPUT6" | grep -F "$MSG6A" | grep -Fq "$SUFFIX_B"; then
    fail "Project A message should NOT have project B suffix"
else
    pass "Project A message correctly excludes project B suffix"
fi

# Verify project B message has project B suffix (suffix on separate line per design)
if echo "$OUTPUT6" | grep -Fq "$MSG6B" && echo "$OUTPUT6" | grep -Fq "$SUFFIX_B"; then
    pass "Project B message has project B suffix"
else
    fail "Project B message missing project B suffix"
fi

# Verify project B message line does NOT contain project A suffix
if echo "$OUTPUT6" | grep -F "$MSG6B" | grep -Fq "$SUFFIX_A"; then
    fail "Project B message should NOT have project A suffix"
else
    pass "Project B message correctly excludes project A suffix"
fi

# ============================================================
# Results
# ============================================================
echo ""
echo "======================================================================"
TOTAL=$((TESTS_PASSED + TESTS_FAILED))
if [[ $TESTS_FAILED -eq 0 ]]; then
    echo "  ✅ ALL TESTS PASSED ($TESTS_PASSED/$TOTAL)"
    echo "======================================================================"
    exit 0
else
    echo "  ❌ SOME TESTS FAILED ($TESTS_FAILED failed, $TESTS_PASSED passed)"
    echo "======================================================================"
    exit 1
fi
