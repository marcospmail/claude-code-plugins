#!/bin/bash
# test-user-prompt-suffix.sh
#
# E2E Test: UserPromptSubmit Hook - User → PM Suffix Injection
#
# Verifies that the user-prompt-suffix.py hook only fires in PM windows
# and correctly stacks yato-level (USER_TO_PM_SUFFIX) and workflow-level
# (user_to_pm_message_suffix) suffixes.
#
# Tests:
# 1. Non-tmux — hook outputs nothing
# 2. PM window with yato suffix only — outputs yato suffix
# 3. PM window with workflow suffix only — outputs workflow suffix
# 4. PM window with both — stacks yato + workflow
# 5. PM window with neither — outputs PM identity block only
# 6. Non-PM window (developer) — outputs nothing
# 7. Ordering — yato suffix before workflow suffix

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="user-prompt-suffix"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$$"
SESSION_NAME="e2e-test-ups-$$"
export TMUX_SOCKET="yato-e2e-test"

echo "======================================================================"
echo "  E2E Test: UserPromptSubmit Hook - User → PM Suffix"
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

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/user-prompt-suffix.py"

# Helper: set config values in defaults.conf
set_config() {
    local user_suffix="$1"
    cat > "$TEST_DIR/config/defaults.conf" <<EOF
PM_TO_AGENTS_SUFFIX=""
AGENTS_TO_PM_SUFFIX=""
CHECKIN_TO_PM_SUFFIX=""
USER_TO_PM_SUFFIX="$user_suffix"
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
EOF
}

# Helper: set workflow suffix field in status.yml
set_workflow_suffix() {
    local value="$1"
    cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$STATUS_FILE')
data = yaml.safe_load(sf.read_text())
data['user_to_pm_message_suffix'] = '$value'
sf.write_text(yaml.dump(data, default_flow_style=False))
"
}

# Helper: run hook inside a tmux pane and capture output to a temp file
# This is necessary because detect_role() uses tmux commands that need
# to connect to the correct tmux server (via inherited TMUX env var).
run_hook_in_pane() {
    local target="$1"
    local outfile="$2"
    rm -f "$outfile"
    tmux -L "$TMUX_SOCKET" send-keys -t "$target" "echo '{\"prompt\":\"test\"}' | HOOK_CWD='$TEST_DIR' YATO_PATH='$TEST_DIR' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$outfile' 2>/dev/null; echo '__DONE__' >> '$outfile'" Enter
    # Wait for completion
    for i in $(seq 1 30); do
        if [[ -f "$outfile" ]] && grep -q '__DONE__' "$outfile" 2>/dev/null; then
            break
        fi
        sleep 1
    done
    # Return output without the __DONE__ marker
    if [[ -f "$outfile" ]]; then
        grep -v '__DONE__' "$outfile"
    fi
}

# ============================================================
# Setup
# ============================================================
echo "Setting up test environment..."
mkdir -p "$TEST_DIR/config"
mkdir -p "$TEST_DIR/.workflow/001-test-user-suffix/agents/pm"
mkdir -p "$TEST_DIR/.workflow/001-test-user-suffix/agents/developer"

# Create initial config with empty suffixes
set_config ""

# Create workflow status.yml
STATUS_FILE="$TEST_DIR/.workflow/001-test-user-suffix/status.yml"
cat > "$STATUS_FILE" <<EOF
status: in-progress
title: "Test user prompt suffix"
initial_request: "Testing user prompt suffix hook"
folder: "$TEST_DIR/.workflow/001-test-user-suffix"
checkin_interval_minutes: 5
session: "$SESSION_NAME"
agent_message_suffix: ""
checkin_message_suffix: ""
agent_to_pm_message_suffix: ""
user_to_pm_message_suffix: ""
EOF

echo "// test project" > "$TEST_DIR/index.js"

echo "Test directory: $TEST_DIR"
echo "Session: $SESSION_NAME"
echo ""

# Create tmux session with PM at window 0, developer at window 1
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm-window" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -t "$SESSION_NAME" -n "dev-window" -c "$TEST_DIR"
sleep 1

# Create identity.yml for PM (window 0)
cat > "$TEST_DIR/.workflow/001-test-user-suffix/agents/pm/identity.yml" <<EOF
name: pm
role: pm
session: "$SESSION_NAME"
window: 0
EOF

# Create identity.yml for developer (window 1)
cat > "$TEST_DIR/.workflow/001-test-user-suffix/agents/developer/identity.yml" <<EOF
name: developer
role: developer
session: "$SESSION_NAME"
window: 1
EOF

echo ""

# ============================================================
# Test 1: Non-tmux — hook outputs nothing
# ============================================================
echo "======================================================================"
echo "  Test 1: Non-tmux — hook outputs nothing"
echo "======================================================================"
echo ""

OUTPUT1=$(echo '{"prompt":"test"}' | HOOK_CWD="$TEST_DIR" YATO_PATH="$TEST_DIR" TMUX="" TMUX_PANE="" uv run --directory "$PROJECT_ROOT" python "$HOOK_SCRIPT" 2>/dev/null)

if [[ -z "$OUTPUT1" ]]; then
    pass "No output when not in tmux"
else
    fail "Should produce no output outside tmux, got: $OUTPUT1"
fi

# ============================================================
# Test 2: PM window with yato suffix only
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 2: PM window with yato suffix only"
echo "======================================================================"
echo ""

YATO_SUFFIX="--YATO_USER_TO_PM--"
set_config "$YATO_SUFFIX"
set_workflow_suffix ""

OUTFILE2="/tmp/e2e-ups-test2-$$"
OUTPUT2=$(run_hook_in_pane "$SESSION_NAME:0" "$OUTFILE2")
rm -f "$OUTFILE2"

if echo "$OUTPUT2" | grep -Fq -- "$YATO_SUFFIX"; then
    pass "Yato-level USER_TO_PM_SUFFIX present"
else
    fail "Yato-level USER_TO_PM_SUFFIX missing. Got: $OUTPUT2"
fi

# ============================================================
# Test 3: PM window with workflow suffix only
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 3: PM window with workflow suffix only"
echo "======================================================================"
echo ""

WF_SUFFIX="--WF_USER_TO_PM--"
set_config ""
set_workflow_suffix "$WF_SUFFIX"

OUTFILE3="/tmp/e2e-ups-test3-$$"
OUTPUT3=$(run_hook_in_pane "$SESSION_NAME:0" "$OUTFILE3")
rm -f "$OUTFILE3"

if echo "$OUTPUT3" | grep -Fq -- "$WF_SUFFIX"; then
    pass "Workflow-level user_to_pm_message_suffix present"
else
    fail "Workflow-level user_to_pm_message_suffix missing. Got: $OUTPUT3"
fi

# ============================================================
# Test 4: PM window with both — stacks yato + workflow
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 4: PM window with both — stacks yato + workflow"
echo "======================================================================"
echo ""

set_config "$YATO_SUFFIX"
set_workflow_suffix "$WF_SUFFIX"

OUTFILE4="/tmp/e2e-ups-test4-$$"
OUTPUT4=$(run_hook_in_pane "$SESSION_NAME:0" "$OUTFILE4")
rm -f "$OUTFILE4"

if echo "$OUTPUT4" | grep -Fq -- "$YATO_SUFFIX"; then
    pass "Yato-level suffix present when both set"
else
    fail "Yato-level suffix missing when both set. Got: $OUTPUT4"
fi

if echo "$OUTPUT4" | grep -Fq -- "$WF_SUFFIX"; then
    pass "Workflow-level suffix present when both set"
else
    fail "Workflow-level suffix missing when both set. Got: $OUTPUT4"
fi

# ============================================================
# Test 5: PM window with neither — outputs PM identity block only
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 5: PM window with neither — outputs PM identity block only"
echo "======================================================================"
echo ""

set_config ""
set_workflow_suffix ""

OUTFILE5="/tmp/e2e-ups-test5-$$"
OUTPUT5=$(run_hook_in_pane "$SESSION_NAME:0" "$OUTFILE5")
rm -f "$OUTFILE5"

if echo "$OUTPUT5" | grep -Fq "You are the PM"; then
    pass "PM identity block present even with empty suffixes"
else
    fail "PM identity block should always be present for PM, got: $OUTPUT5"
fi

# ============================================================
# Test 6: Non-PM window (developer) — outputs nothing
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 6: Non-PM window (developer) — outputs nothing"
echo "======================================================================"
echo ""

set_config "$YATO_SUFFIX"
set_workflow_suffix "$WF_SUFFIX"

OUTFILE6="/tmp/e2e-ups-test6-$$"
OUTPUT6=$(run_hook_in_pane "$SESSION_NAME:1" "$OUTFILE6")
rm -f "$OUTFILE6"

if [[ -z "$OUTPUT6" ]]; then
    pass "No output for non-PM (developer) window"
else
    fail "Should produce no output for developer window, got: $OUTPUT6"
fi

# ============================================================
# Test 7: Ordering — yato suffix before workflow suffix
# ============================================================
echo ""
echo "======================================================================"
echo "  Test 7: Ordering — yato suffix before workflow suffix"
echo "======================================================================"
echo ""

ORDER_YATO="--ORDER_FIRST_YATO--"
ORDER_WF="--ORDER_SECOND_WF--"

set_config "$ORDER_YATO"
set_workflow_suffix "$ORDER_WF"

OUTFILE7="/tmp/e2e-ups-test7-$$"
OUTPUT7=$(run_hook_in_pane "$SESSION_NAME:0" "$OUTFILE7")
rm -f "$OUTFILE7"

# Verify both markers present
if echo "$OUTPUT7" | grep -Fq -- "$ORDER_YATO"; then
    pass "Yato ordering marker present"
else
    fail "Yato ordering marker missing"
fi

if echo "$OUTPUT7" | grep -Fq -- "$ORDER_WF"; then
    pass "Workflow ordering marker present"
else
    fail "Workflow ordering marker missing"
fi

# Check ordering: yato should appear before workflow in output
YATO_LINE=$(echo "$OUTPUT7" | grep -Fn -- "$ORDER_YATO" | head -1 | cut -d: -f1)
WF_LINE=$(echo "$OUTPUT7" | grep -Fn -- "$ORDER_WF" | head -1 | cut -d: -f1)

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
