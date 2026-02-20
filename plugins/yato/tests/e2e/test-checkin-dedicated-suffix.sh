#!/bin/bash
# test-checkin-dedicated-suffix.sh
#
# E2E Test: Dedicated CHECKIN_TO_PM_SUFFIX Configuration
#
# Verifies that check-in messages use CHECKIN_TO_PM_SUFFIX (not AGENTS_TO_PM_SUFFIX)
# from config/defaults.conf, and that both yato-level and workflow-level suffixes
# stack correctly for check-in messages.
#
# Tests:
# 1. Check-in uses CHECKIN_TO_PM_SUFFIX (not AGENTS_TO_PM_SUFFIX)
# 2. Both levels stacked (CHECKIN_TO_PM_SUFFIX + checkin_message_suffix)
# 3. Only yato-level set (CHECKIN_TO_PM_SUFFIX only)
# 4. Empty CHECKIN_TO_PM_SUFFIX (no yato suffix appended)
# 5. Ordering: Yato suffix (CHECKIN_TO_PM_SUFFIX) before workflow suffix (checkin_message_suffix)

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="checkin-dedicated-suffix"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-cds-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Dedicated CHECKIN_TO_PM_SUFFIX"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
}
trap cleanup EXIT

# Helper: send a command to Claude and approve the permission prompt
send_to_claude() {
    local cmd="$1"
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "$cmd"
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
    sleep 15  # Wait for Claude to show permission prompt

    # Approve the permission prompt (press Enter to accept "Yes")
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
    sleep 10  # Wait for command to execute
}

# Helper: set config values in defaults.conf
set_config() {
    local pm_suffix="$1"
    local agent_suffix="$2"
    local checkin_suffix="$3"
    cat > "$TEST_DIR/config/defaults.conf" <<EOF
PM_TO_AGENTS_SUFFIX="$pm_suffix"
AGENTS_TO_PM_SUFFIX="$agent_suffix"
CHECKIN_TO_PM_SUFFIX="$checkin_suffix"
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
EOF
}

# Helper: set workflow suffix fields in status.yml
set_workflow_suffix() {
    local field="$1"
    local value="$2"
    cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
data['$field'] = '$value'
sf.write_text(yaml.dump(data, default_flow_style=False))
"
}

# ============================================================
# QA Validator: Check real Claude Code environment
# ============================================================
echo "QA Validator: Checking Claude Code environment..."
if ! which claude >/dev/null 2>&1; then
    echo "ERROR: 'claude' command not found in PATH"
    echo "This test requires a real Claude Code installation."
    exit 99
fi
echo "  claude found: $(which claude)"
echo ""

# ============================================================
# Setup
# ============================================================
echo "Setting up test environment..."
mkdir -p "$TEST_DIR/config"
mkdir -p "$TEST_DIR/.workflow/001-test-checkin-suffix"

# Create initial config with empty suffixes
set_config "" "" ""

# Create workflow status.yml
STATUS_FILE="$TEST_DIR/.workflow/001-test-checkin-suffix/status.yml"
cat > "$STATUS_FILE" <<EOF
status: in-progress
title: "Test checkin dedicated suffix"
initial_request: "Testing dedicated CHECKIN_TO_PM_SUFFIX"
folder: "$TEST_DIR/.workflow/001-test-checkin-suffix"
checkin_interval_minutes: 5
session: "$SESSION_NAME"
agent_message_suffix: ""
checkin_message_suffix: ""
agent_to_pm_message_suffix: ""
EOF

echo "// test project" > "$TEST_DIR/index.js"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# Create tmux session mimicking real Yato layout:
#   Window 0: pane 0 = checkin display, pane 1 = PM (notify_pm target)
#   Window 1: Claude (for running test commands)
echo "Starting tmux session and Claude..."
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 220 -y 50 -n "pm-window" -c "$TEST_DIR"
# Split window 0 to create pane 0 and pane 1 (PM pane at 0.1)
tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -h -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "claude" -c "$TEST_DIR"

# Disable flow control in PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "stty -ixon" Enter
sleep 1

# Start Claude in window 1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "claude" Enter

echo "Waiting for Claude to start..."
sleep 8

OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p 2>/dev/null)
if echo "$OUTPUT" | grep -qi "trust"; then
    echo "Trust prompt found, accepting..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" Enter
    sleep 15
else
    echo "No trust prompt found, continuing..."
    sleep 5
fi

echo ""

# ============================================================
# Test 1: Check-in uses CHECKIN_TO_PM_SUFFIX (not AGENTS_TO_PM_SUFFIX)
# ============================================================
echo "======================================================================"
echo "  Test 1: Check-in uses CHECKIN_TO_PM_SUFFIX (not AGENTS_TO_PM_SUFFIX)"
echo "======================================================================"
echo ""

CHECKIN_YATO_SUFFIX="--CHECKIN_YATO--"
AGENT_YATO_SUFFIX="--AGENT_YATO--"

set_config "" "$AGENT_YATO_SUFFIX" "$CHECKIN_YATO_SUFFIX"

# Clear PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG1="CHECKIN_DEDICATED_$(date +%s)"

# Simulate what the checkin daemon does: read CHECKIN_TO_PM_SUFFIX and workflow suffix, stack, send to PM
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"
import yaml
from pathlib import Path
from lib.config import load_config, get as get_config
load_config(force_reload=True)
from lib.tmux_utils import send_message
yato_suffix = get_config('CHECKIN_TO_PM_SUFFIX')
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
wf_suffix = data.get('checkin_message_suffix', '')
msg = '$MSG1'
if yato_suffix:
    msg = msg + chr(10) + chr(10) + yato_suffix
if wf_suffix:
    msg = msg + chr(10) + chr(10) + wf_suffix
send_message('$SESSION_NAME:0.1', msg)
\""

# Capture from PM pane (0.1)
OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

echo "Debug - PM pane (0.1):"
echo "$OUTPUT1" | tail -15
echo ""

if echo "$OUTPUT1" | grep -Fq -- "$MSG1"; then
    pass "Check-in message delivered"
else
    fail "Check-in message not delivered"
fi

if echo "$OUTPUT1" | grep -Fq -- "$CHECKIN_YATO_SUFFIX"; then
    pass "CHECKIN_TO_PM_SUFFIX present in check-in message"
else
    fail "CHECKIN_TO_PM_SUFFIX missing from check-in message"
fi

if echo "$OUTPUT1" | grep -Fq -- "$AGENT_YATO_SUFFIX"; then
    fail "AGENTS_TO_PM_SUFFIX should NOT appear in check-in message"
else
    pass "AGENTS_TO_PM_SUFFIX correctly absent from check-in message"
fi

# ============================================================
# Test 2: Both levels stacked (CHECKIN_TO_PM_SUFFIX + checkin_message_suffix)
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 2: Both levels stacked"
echo "======================================================================"
echo ""

CHECKIN_WF_SUFFIX="--CHECKIN_WF--"

set_config "" "$AGENT_YATO_SUFFIX" "$CHECKIN_YATO_SUFFIX"
set_workflow_suffix "checkin_message_suffix" "$CHECKIN_WF_SUFFIX"

# Clear PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG2="CHECKIN_BOTH_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"
import yaml
from pathlib import Path
from lib.config import load_config, get as get_config
load_config(force_reload=True)
from lib.tmux_utils import send_message
yato_suffix = get_config('CHECKIN_TO_PM_SUFFIX')
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
wf_suffix = data.get('checkin_message_suffix', '')
msg = '$MSG2'
if yato_suffix:
    msg = msg + chr(10) + chr(10) + yato_suffix
if wf_suffix:
    msg = msg + chr(10) + chr(10) + wf_suffix
send_message('$SESSION_NAME:0.1', msg)
\""

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

echo "Debug - PM pane (0.1):"
echo "$OUTPUT2" | tail -15
echo ""

if echo "$OUTPUT2" | grep -Fq -- "$MSG2"; then
    pass "Check-in message delivered"
else
    fail "Check-in message not delivered"
fi

if echo "$OUTPUT2" | grep -Fq -- "$CHECKIN_YATO_SUFFIX"; then
    pass "CHECKIN_TO_PM_SUFFIX present (yato-level)"
else
    fail "CHECKIN_TO_PM_SUFFIX missing (yato-level)"
fi

if echo "$OUTPUT2" | grep -Fq -- "$CHECKIN_WF_SUFFIX"; then
    pass "checkin_message_suffix present (workflow-level)"
else
    fail "checkin_message_suffix missing (workflow-level)"
fi

# ============================================================
# Test 3: Only yato-level set (CHECKIN_TO_PM_SUFFIX only)
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 3: Only yato-level set (CHECKIN_TO_PM_SUFFIX only)"
echo "======================================================================"
echo ""

set_workflow_suffix "checkin_message_suffix" ""

# Clear PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG3="CHECKIN_YATO_ONLY_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"
import yaml
from pathlib import Path
from lib.config import load_config, get as get_config
load_config(force_reload=True)
from lib.tmux_utils import send_message
yato_suffix = get_config('CHECKIN_TO_PM_SUFFIX')
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
wf_suffix = data.get('checkin_message_suffix', '')
msg = '$MSG3'
if yato_suffix:
    msg = msg + chr(10) + chr(10) + yato_suffix
if wf_suffix:
    msg = msg + chr(10) + chr(10) + wf_suffix
send_message('$SESSION_NAME:0.1', msg)
\""

OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

if echo "$OUTPUT3" | grep -Fq -- "$CHECKIN_YATO_SUFFIX"; then
    pass "CHECKIN_TO_PM_SUFFIX present when only yato-level set"
else
    fail "CHECKIN_TO_PM_SUFFIX missing when only yato-level set"
fi

if echo "$OUTPUT3" | grep -Fq -- "$CHECKIN_WF_SUFFIX"; then
    fail "Workflow suffix should NOT appear when empty"
else
    pass "No workflow suffix when empty"
fi

# ============================================================
# Test 4: Empty CHECKIN_TO_PM_SUFFIX (no yato suffix appended)
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 4: Empty CHECKIN_TO_PM_SUFFIX"
echo "======================================================================"
echo ""

set_config "" "$AGENT_YATO_SUFFIX" ""
set_workflow_suffix "checkin_message_suffix" ""

# Clear PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG4="CHECKIN_EMPTY_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"
import yaml
from pathlib import Path
from lib.config import load_config, get as get_config
load_config(force_reload=True)
from lib.tmux_utils import send_message
yato_suffix = get_config('CHECKIN_TO_PM_SUFFIX')
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
wf_suffix = data.get('checkin_message_suffix', '')
msg = '$MSG4'
if yato_suffix:
    msg = msg + chr(10) + chr(10) + yato_suffix
if wf_suffix:
    msg = msg + chr(10) + chr(10) + wf_suffix
send_message('$SESSION_NAME:0.1', msg)
\""

OUTPUT4=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

if echo "$OUTPUT4" | grep -Fq -- "$MSG4"; then
    pass "Clean message delivered"
else
    fail "Clean message not delivered"
fi

if echo "$OUTPUT4" | grep -Fq -- "$CHECKIN_YATO_SUFFIX"; then
    fail "CHECKIN_TO_PM_SUFFIX should NOT appear when empty"
else
    pass "No CHECKIN_TO_PM_SUFFIX when empty"
fi

if echo "$OUTPUT4" | grep -Fq -- "$AGENT_YATO_SUFFIX"; then
    fail "AGENTS_TO_PM_SUFFIX should NOT appear in check-in (even when set)"
else
    pass "AGENTS_TO_PM_SUFFIX correctly absent from check-in with empty CHECKIN_TO_PM_SUFFIX"
fi

# ============================================================
# Test 5: Ordering - CHECKIN_TO_PM_SUFFIX before checkin_message_suffix
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 5: Ordering - Yato suffix before workflow suffix"
echo "======================================================================"
echo ""

ORDER_YATO="--ORDER_FIRST_CHECKIN--"
ORDER_WF="--ORDER_SECOND_WF--"

set_config "" "$AGENT_YATO_SUFFIX" "$ORDER_YATO"
set_workflow_suffix "checkin_message_suffix" "$ORDER_WF"

# Clear PM pane (0.1) — both visible area and scrollback buffer
# (scrollback can contain markers from previous tests that confuse line-based ordering checks)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
tmux -L "$TMUX_SOCKET" clear-history -t "$SESSION_NAME:0.1" 2>/dev/null || true
sleep 1

MSG5="CHECKIN_ORDER_$(date +%s)"

# Run directly (not through Claude) to avoid session timeout after multiple send_to_claude calls
cd "$PROJECT_ROOT" && YATO_PATH="$TEST_DIR" TMUX_SOCKET="$TMUX_SOCKET" uv run python -c "
import yaml
from pathlib import Path
from lib.config import load_config, get as get_config
load_config(force_reload=True)
from lib.tmux_utils import send_message
yato_suffix = get_config('CHECKIN_TO_PM_SUFFIX')
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
wf_suffix = data.get('checkin_message_suffix', '')
msg = '$MSG5'
if yato_suffix:
    msg = msg + chr(10) + chr(10) + yato_suffix
if wf_suffix:
    msg = msg + chr(10) + chr(10) + wf_suffix
send_message('$SESSION_NAME:0.1', msg)
"
sleep 3

# Capture full pane as a single string for ordering check
OUTPUT5=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

echo "Debug - PM pane (ordering test):"
echo "$OUTPUT5" | tail -20
echo ""

# Verify both markers are present
if echo "$OUTPUT5" | grep -Fq -- "$ORDER_YATO"; then
    pass "Yato ordering marker present"
else
    fail "Yato ordering marker missing"
fi

if echo "$OUTPUT5" | grep -Fq -- "$ORDER_WF"; then
    pass "Workflow ordering marker present"
else
    fail "Workflow ordering marker missing"
fi

# Check ordering: use byte offsets to avoid false positives from terminal wrapping
# (tmux pane wrapping can split markers across lines, making line-number checks unreliable)
YATO_POS=$(echo "$OUTPUT5" | grep -Fbo -- "$ORDER_YATO" | head -1 | cut -d: -f1)
WF_POS=$(echo "$OUTPUT5" | grep -Fbo -- "$ORDER_WF" | head -1 | cut -d: -f1)

if [[ -n "$YATO_POS" && -n "$WF_POS" && "$YATO_POS" -lt "$WF_POS" ]]; then
    pass "Yato suffix (byte $YATO_POS) appears before workflow suffix (byte $WF_POS)"
else
    fail "Ordering incorrect: yato byte=$YATO_POS, workflow byte=$WF_POS (yato should be first)"
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
