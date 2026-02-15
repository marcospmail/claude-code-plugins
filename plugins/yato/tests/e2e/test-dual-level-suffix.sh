#!/bin/bash
# test-dual-level-suffix.sh
#
# E2E Test: Dual-Level Message Suffix System (Yato-Level + Workflow-Level)
#
# Verifies the stacking behavior of yato-level (defaults.conf) and workflow-level
# (status.yml) suffixes. Both are appended if set, with yato before workflow.
#
# Tests:
# 1. PM -> Agent: Both suffixes stacked (yato PM_TO_AGENTS_SUFFIX + workflow agent_message_suffix)
# 2. PM -> Agent: Only yato suffix (PM_TO_AGENTS_SUFFIX only)
# 3. PM -> Agent: Only workflow suffix (agent_message_suffix only)
# 4. PM -> Agent: Neither set (clean message)
# 5. Agent -> PM: Both suffixes stacked (yato AGENTS_TO_PM_SUFFIX + workflow agent_to_pm_message_suffix)
# 6. Agent -> PM: Only yato suffix (AGENTS_TO_PM_SUFFIX only)
# 7. Check-in -> PM: Both suffixes stacked (AGENTS_TO_PM_SUFFIX + checkin_message_suffix)
# 8. Ordering: Yato suffix always before workflow suffix

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="dual-level-suffix"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-dls-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: Dual-Level Message Suffix System"
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
    cat > "$TEST_DIR/config/defaults.conf" <<EOF
PM_TO_AGENTS_SUFFIX="$pm_suffix"
AGENTS_TO_PM_SUFFIX="$agent_suffix"
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
mkdir -p "$TEST_DIR/.workflow/001-test-dual-suffix"

# Create initial config with empty suffixes
set_config "" ""

# Create workflow status.yml
STATUS_FILE="$TEST_DIR/.workflow/001-test-dual-suffix/status.yml"
cat > "$STATUS_FILE" <<EOF
status: in-progress
title: "Test dual-level suffix"
initial_request: "Testing dual-level suffix system"
folder: "$TEST_DIR/.workflow/001-test-dual-suffix"
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
#   Window 2: Agent (receiver for PM->agent messages)
echo "Starting tmux session and Claude..."
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm-window" -c "$TEST_DIR"
# Split window 0 to create pane 0 and pane 1 (PM pane at 0.1)
tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -h -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "claude" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "agent" -c "$TEST_DIR"

# Disable flow control in PM pane (0.1) and Agent window (2)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "stty -ixon" Enter
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "stty -ixon" Enter
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
# Test 1: PM -> Agent: Both suffixes stacked
# ============================================================
echo "======================================================================"
echo "  Test 1: PM -> Agent: Both suffixes stacked"
echo "======================================================================"
echo ""

YATO_PM_SUFFIX="--YATO_PM_GLOBAL--"
WF_AGENT_SUFFIX="--WF_AGENT_LOCAL--"

set_config "$YATO_PM_SUFFIX" ""
set_workflow_suffix "agent_message_suffix" "$WF_AGENT_SUFFIX"

MSG1="BOTH_PM_TO_AGENT_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG1', workflow_status_file='$STATUS_FILE')\""

OUTPUT1=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

echo "Debug - Agent pane:"
echo "$OUTPUT1" | tail -15
echo ""

if echo "$OUTPUT1" | grep -Fq -- "$MSG1"; then
    pass "Original message delivered"
else
    fail "Original message not found"
fi

if echo "$OUTPUT1" | grep -Fq -- "$YATO_PM_SUFFIX"; then
    pass "Yato-level PM_TO_AGENTS_SUFFIX present"
else
    fail "Yato-level PM_TO_AGENTS_SUFFIX missing"
fi

if echo "$OUTPUT1" | grep -Fq -- "$WF_AGENT_SUFFIX"; then
    pass "Workflow-level agent_message_suffix present"
else
    fail "Workflow-level agent_message_suffix missing"
fi

# ============================================================
# Test 2: PM -> Agent: Only yato suffix
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 2: PM -> Agent: Only yato suffix"
echo "======================================================================"
echo ""

set_workflow_suffix "agent_message_suffix" ""
# Clear agent pane
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "clear" Enter
sleep 1

MSG2="YATO_ONLY_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG2', workflow_status_file='$STATUS_FILE')\""

OUTPUT2=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

if echo "$OUTPUT2" | grep -Fq -- "$YATO_PM_SUFFIX"; then
    pass "Yato-level suffix present when only yato set"
else
    fail "Yato-level suffix missing when only yato set"
fi

if echo "$OUTPUT2" | grep -Fq -- "$WF_AGENT_SUFFIX"; then
    fail "Workflow suffix should NOT appear when empty"
else
    pass "No workflow suffix when empty"
fi

# ============================================================
# Test 3: PM -> Agent: Only workflow suffix
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 3: PM -> Agent: Only workflow suffix"
echo "======================================================================"
echo ""

set_config "" ""
set_workflow_suffix "agent_message_suffix" "$WF_AGENT_SUFFIX"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "clear" Enter
sleep 1

MSG3="WF_ONLY_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG3', workflow_status_file='$STATUS_FILE')\""

OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

if echo "$OUTPUT3" | grep -Fq -- "$WF_AGENT_SUFFIX"; then
    pass "Workflow-level suffix present when only workflow set"
else
    fail "Workflow-level suffix missing when only workflow set"
fi

if echo "$OUTPUT3" | grep -Fq -- "$YATO_PM_SUFFIX"; then
    fail "Yato suffix should NOT appear when empty"
else
    pass "No yato suffix when empty"
fi

# ============================================================
# Test 4: PM -> Agent: Neither set
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 4: PM -> Agent: Neither suffix set"
echo "======================================================================"
echo ""

set_config "" ""
set_workflow_suffix "agent_message_suffix" ""

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "clear" Enter
sleep 1

MSG4="CLEAN_MSG_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG4', workflow_status_file='$STATUS_FILE')\""

OUTPUT4=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

if echo "$OUTPUT4" | grep -Fq -- "$MSG4"; then
    pass "Clean message delivered"
else
    fail "Clean message not delivered"
fi

MSG4_LINE=$(echo "$OUTPUT4" | grep -F -- "$MSG4" | tail -1)
if echo "$MSG4_LINE" | grep -Fq "SUFFIX"; then
    fail "No suffix markers should appear with empty config"
else
    pass "No suffix markers on clean message"
fi

# ============================================================
# Test 5: Agent -> PM: Both suffixes stacked
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 5: Agent -> PM: Both suffixes stacked"
echo "======================================================================"
echo ""

YATO_AGENT_SUFFIX="--YATO_AGENT_GLOBAL--"
WF_AGENT_TO_PM_SUFFIX="--WF_AGENT_TO_PM_LOCAL--"

set_config "" "$YATO_AGENT_SUFFIX"
set_workflow_suffix "agent_to_pm_message_suffix" "$WF_AGENT_TO_PM_SUFFIX"

# Clear PM pane (0.1) - notify_pm sends to session:0.1
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG5="AGENT_TO_PM_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import notify_pm; notify_pm('$MSG5', session='$SESSION_NAME', workflow_status_file='$STATUS_FILE')\""

# Capture from PM pane (0.1)
OUTPUT5=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

echo "Debug - PM pane (0.1):"
echo "$OUTPUT5" | tail -15
echo ""

if echo "$OUTPUT5" | grep -Fq -- "$MSG5"; then
    pass "Agent->PM message delivered"
else
    fail "Agent->PM message not delivered"
fi

if echo "$OUTPUT5" | grep -Fq -- "$YATO_AGENT_SUFFIX"; then
    pass "Yato-level AGENTS_TO_PM_SUFFIX present"
else
    fail "Yato-level AGENTS_TO_PM_SUFFIX missing"
fi

if echo "$OUTPUT5" | grep -Fq -- "$WF_AGENT_TO_PM_SUFFIX"; then
    pass "Workflow-level agent_to_pm_message_suffix present"
else
    fail "Workflow-level agent_to_pm_message_suffix missing"
fi

# ============================================================
# Test 6: Agent -> PM: Only yato suffix
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 6: Agent -> PM: Only yato suffix"
echo "======================================================================"
echo ""

set_workflow_suffix "agent_to_pm_message_suffix" ""

# Clear PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG6="AGENT_YATO_ONLY_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import notify_pm; notify_pm('$MSG6', session='$SESSION_NAME', workflow_status_file='$STATUS_FILE')\""

# Capture from PM pane (0.1)
OUTPUT6=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

if echo "$OUTPUT6" | grep -Fq -- "$YATO_AGENT_SUFFIX"; then
    pass "Yato-level suffix present when only yato set"
else
    fail "Yato-level suffix missing when only yato set"
fi

if echo "$OUTPUT6" | grep -Fq -- "$WF_AGENT_TO_PM_SUFFIX"; then
    fail "Workflow suffix should NOT appear when empty"
else
    pass "No workflow suffix when empty"
fi

# ============================================================
# Test 7: Check-in -> PM: Both suffixes stacked
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 7: Check-in -> PM: Both suffixes stacked"
echo "======================================================================"
echo ""

CHECKIN_WF_SUFFIX="--CHECKIN_WF_LOCAL--"
set_workflow_suffix "checkin_message_suffix" "$CHECKIN_WF_SUFFIX"

# Clear PM pane (0.1)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" "clear" Enter
sleep 1

MSG7="CHECKIN_DUAL_$(date +%s)"

# Simulate what the checkin daemon does: read both suffixes and stack, send to PM pane (0.1)
send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"
import yaml
from pathlib import Path
from lib.config import load_config, get as get_config
load_config(force_reload=True)
from lib.tmux_utils import send_message
yato_suffix = get_config('AGENTS_TO_PM_SUFFIX')
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
wf_suffix = data.get('checkin_message_suffix', '')
msg = '$MSG7'
if yato_suffix:
    msg = msg + chr(10) + chr(10) + yato_suffix
if wf_suffix:
    msg = msg + chr(10) + chr(10) + wf_suffix
send_message('$SESSION_NAME:0.1', msg)
\""

# Capture from PM pane (0.1)
OUTPUT7=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p)

echo "Debug - PM pane (0.1) after checkin:"
echo "$OUTPUT7" | tail -15
echo ""

if echo "$OUTPUT7" | grep -Fq -- "$MSG7"; then
    pass "Check-in message delivered"
else
    fail "Check-in message not delivered"
fi

if echo "$OUTPUT7" | grep -Fq -- "$YATO_AGENT_SUFFIX"; then
    pass "Yato-level AGENTS_TO_PM_SUFFIX in check-in message"
else
    fail "Yato-level AGENTS_TO_PM_SUFFIX missing from check-in"
fi

if echo "$OUTPUT7" | grep -Fq -- "$CHECKIN_WF_SUFFIX"; then
    pass "Workflow-level checkin_message_suffix in check-in message"
else
    fail "Workflow-level checkin_message_suffix missing from check-in"
fi

# ============================================================
# Test 8: Ordering - Yato suffix before workflow suffix
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 8: Ordering - Yato suffix appears before workflow suffix"
echo "======================================================================"
echo ""

# Use unique markers to verify ordering
ORDER_YATO="--ORDER_FIRST_YATO--"
ORDER_WF="--ORDER_SECOND_WF--"

set_config "$ORDER_YATO" ""
set_workflow_suffix "agent_message_suffix" "$ORDER_WF"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "clear" Enter
sleep 1

MSG8="ORDER_TEST_$(date +%s)"

send_to_claude "Run this exact command in bash, nothing else: cd $PROJECT_ROOT && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' uv run python -c \"from lib.config import load_config; load_config(force_reload=True); from lib.tmux_utils import send_message; send_message('$SESSION_NAME:2', '$MSG8', workflow_status_file='$STATUS_FILE')\""

# Capture full pane as a single string for ordering check
OUTPUT8=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)

echo "Debug - Agent pane (ordering test):"
echo "$OUTPUT8" | tail -20
echo ""

# Verify both markers are present
if echo "$OUTPUT8" | grep -Fq -- "$ORDER_YATO"; then
    pass "Yato ordering marker present"
else
    fail "Yato ordering marker missing"
fi

if echo "$OUTPUT8" | grep -Fq -- "$ORDER_WF"; then
    pass "Workflow ordering marker present"
else
    fail "Workflow ordering marker missing"
fi

# Check ordering: find line numbers and verify yato appears first
YATO_LINE=$(echo "$OUTPUT8" | grep -Fn -- "$ORDER_YATO" | head -1 | cut -d: -f1)
WF_LINE=$(echo "$OUTPUT8" | grep -Fn -- "$ORDER_WF" | head -1 | cut -d: -f1)

if [[ -n "$YATO_LINE" && -n "$WF_LINE" && "$YATO_LINE" -lt "$WF_LINE" ]]; then
    pass "Yato suffix (line $YATO_LINE) appears before workflow suffix (line $WF_LINE)"
else
    fail "Ordering incorrect: yato line=$YATO_LINE, workflow line=$WF_LINE (yato should be first)"
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
