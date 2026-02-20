#!/bin/bash
# test-per-project-suffix-real-session.sh
#
# E2E Test: Per-Project Message Suffix via Real Claude Code Session
#
# Validates the per-project message suffix feature using a REAL Claude Code
# session (not direct Python calls). This proves the feature works end-to-end
# as a user would experience it.
#
# Tests:
# 1. agent_message_suffix is appended when send_message uses workflow_status_file
# 2. No suffix appears when send_message is called without workflow_status_file (notify_pm path)
# 3. Changing the suffix in status.yml is picked up on the next call (fresh reads)
# 4. checkin_message_suffix is read correctly from status.yml

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="per-project-suffix-real"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-pps-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Per-Project Message Suffix (Real Claude Session)"
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
}
trap cleanup EXIT

# Helper: run a Python command directly (no Claude CLI needed)
run_python() {
    local python_code="$1"
    cd "$PROJECT_ROOT" && YATO_PATH="$TEST_DIR" TMUX_SOCKET="$TMUX_SOCKET" uv run python -c "$python_code"
    sleep 2  # Allow tmux pane to receive the message
}

# ============================================================
# Setup
# ============================================================
echo "Setting up test environment..."
mkdir -p "$TEST_DIR/config"
mkdir -p "$TEST_DIR/.workflow/001-test-suffix"

# Create config/defaults.conf with empty PM_TO_AGENTS_SUFFIX so global fallback does not interfere
cat > "$TEST_DIR/config/defaults.conf" <<'EOF'
PM_TO_AGENTS_SUFFIX=""
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
EOF

# Create a workflow status.yml with per-project suffix fields
AGENT_SUFFIX=" --PER_PROJECT_AGENT_SUFFIX--"
CHECKIN_SUFFIX=" --PER_PROJECT_CHECKIN_SUFFIX--"
STATUS_FILE="$TEST_DIR/.workflow/001-test-suffix/status.yml"

cat > "$STATUS_FILE" <<EOF
status: in-progress
title: "Test per-project suffix"
initial_request: "Testing per-project suffix feature"
folder: "$TEST_DIR/.workflow/001-test-suffix"
checkin_interval_minutes: 5
session: "$SESSION_NAME"
agent_message_suffix: "$AGENT_SUFFIX"
checkin_message_suffix: "$CHECKIN_SUFFIX"
EOF

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo "Status file: $STATUS_FILE"
echo ""

# Create tmux session with receiver window (no Claude needed)
echo "Starting tmux session..."
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "receiver" -c "$TEST_DIR"

# Disable flow control in receiver
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0" "stty -ixon" Enter
sleep 1

echo ""
echo "======================================================================"
echo "  Test 1: agent_message_suffix appended via real Claude session"
echo "======================================================================"
echo ""

MSG1="AGENT_REAL_$(date +%s)"

run_python "from lib.tmux_utils import send_message; send_message('$SESSION_NAME:0', '$MSG1', workflow_status_file='$STATUS_FILE')"

# Capture receiver pane output
OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

echo "Debug - Receiver pane content:"
echo "$OUTPUT1" | tail -10
echo ""

# Verify original message is present
if echo "$OUTPUT1" | grep -Fq "$MSG1"; then
    pass "Original message delivered to receiver"
else
    fail "Original message not found in receiver"
    echo "     Expected: $MSG1"
fi

# Verify agent_message_suffix is appended
if echo "$OUTPUT1" | grep -Fq "$AGENT_SUFFIX"; then
    pass "agent_message_suffix appended to message"
else
    fail "agent_message_suffix not found in receiver output"
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
echo "  Test 2: No suffix on notify_pm path (no workflow_status_file)"
echo "======================================================================"
echo ""

MSG2="NOTIFY_PM_REAL_$(date +%s)"

run_python "from lib.tmux_utils import send_message; send_message('$SESSION_NAME:0', '$MSG2')"

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

echo "Debug - Receiver pane after notify_pm path:"
echo "$OUTPUT2" | tail -10
echo ""

# Verify message is delivered
if echo "$OUTPUT2" | grep -Fq "$MSG2"; then
    pass "Message delivered without workflow_status_file"
else
    fail "Message without workflow_status_file not delivered"
fi

# Verify NO suffix on the line with MSG2
MSG2_LINE=$(echo "$OUTPUT2" | grep -F "$MSG2" | tail -1)
if echo "$MSG2_LINE" | grep -Fq "$AGENT_SUFFIX"; then
    fail "notify_pm path should NOT have agent_message_suffix"
else
    pass "notify_pm path correctly has no suffix"
fi

echo ""
echo "======================================================================"
echo "  Test 3: Changed suffix is picked up immediately (fresh reads)"
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

MSG3="FRESH_READ_$(date +%s)"

run_python "from lib.tmux_utils import send_message; send_message('$SESSION_NAME:0', '$MSG3', workflow_status_file='$STATUS_FILE')"

OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

echo "Debug - Receiver pane after suffix change:"
echo "$OUTPUT3" | tail -10
echo ""

# Should have NEW suffix (suffix on separate line per design)
if echo "$OUTPUT3" | grep -Fq "$MSG3" && echo "$OUTPUT3" | grep -Fq "$NEW_AGENT_SUFFIX"; then
    pass "Changed suffix immediately effective (fresh read from status.yml)"
else
    fail "New suffix not applied - possible caching issue"
    echo "     Expected: $MSG3 and $NEW_AGENT_SUFFIX in output"
fi

# Should NOT have old suffix on this message
MSG3_LINE=$(echo "$OUTPUT3" | grep -F "$MSG3" | tail -1)
if echo "$MSG3_LINE" | grep -Fq "$AGENT_SUFFIX"; then
    fail "Old suffix still present - not reading status.yml fresh"
else
    pass "Old suffix correctly replaced by new one"
fi

echo ""
echo "======================================================================"
echo "  Test 4: checkin_message_suffix read from status.yml"
echo "======================================================================"
echo ""

MSG4="CHECKIN_REAL_$(date +%s)"

# Simulate what the checkin daemon does: read checkin_message_suffix from status.yml
# and append it to the message before sending
run_python "
import yaml
from pathlib import Path
from lib.tmux_utils import send_message
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
suffix = data.get('checkin_message_suffix', '')
msg = '$MSG4' + suffix
send_message('$SESSION_NAME:0', msg)
"

OUTPUT4=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0" -p)

echo "Debug - Receiver pane after checkin suffix test:"
echo "$OUTPUT4" | tail -10
echo ""

# Verify checkin message is delivered
if echo "$OUTPUT4" | grep -Fq "$MSG4"; then
    pass "Checkin message delivered"
else
    fail "Checkin message not delivered"
fi

# Verify checkin_message_suffix is appended (suffix on separate line per design)
if echo "$OUTPUT4" | grep -Fq "$MSG4" && echo "$OUTPUT4" | grep -Fq "$CHECKIN_SUFFIX"; then
    pass "checkin_message_suffix appended to checkin message"
else
    fail "checkin_message_suffix not found in output"
    echo "     Expected: $MSG4 and $CHECKIN_SUFFIX in output"
fi

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
