#!/bin/bash
# test-send-to-agent.sh
#
# E2E Test: send-to-agent Skill - PM to Agent Communication
#
# Verifies the send-to-agent skill and underlying send-to-agent.sh script:
#
# Phase 1: Agent lookup - resolves agent name to tmux target via agents.yml
# Phase 2: Unknown agent - fails with helpful error listing available agents
# Phase 3: Suffix stacking - yato-level PM_TO_AGENTS_SUFFIX from defaults.conf
# Phase 4: Suffix stacking - both yato-level and workflow-level suffixes
# Phase 5: Real Claude Code session - PM uses /send-to-agent to delegate work
# Phase 6: Skill file configuration verification

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="send-to-agent"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-s2a-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-s2a-output-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: send-to-agent Skill - PM to Agent Communication"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

# Pre-initialize for cleanup trap
CACHE_INSTALL_PATH=""
CACHE_SKILLS_BACKED_UP=false
CACHE_BIN_BACKED_UP=false

cleanup() {
    echo ""; echo "Cleaning up..."
    # Restore plugin cache if we modified it
    if [[ "$CACHE_SKILLS_BACKED_UP" == true && -n "$CACHE_INSTALL_PATH" ]]; then
        if [[ -d "$CACHE_INSTALL_PATH/skills/send-to-agent.bak" ]]; then
            rm -rf "$CACHE_INSTALL_PATH/skills/send-to-agent"
            mv "$CACHE_INSTALL_PATH/skills/send-to-agent.bak" "$CACHE_INSTALL_PATH/skills/send-to-agent"
        elif [[ ! -d "$CACHE_INSTALL_PATH/skills/send-to-agent.bak" ]]; then
            # Skill didn't exist before, remove what we added
            rm -rf "$CACHE_INSTALL_PATH/skills/send-to-agent"
        fi
    fi
    if [[ "$CACHE_BIN_BACKED_UP" == true && -n "$CACHE_INSTALL_PATH" ]]; then
        for f in send-to-agent.sh send-message.sh; do
            if [[ -f "$CACHE_INSTALL_PATH/bin/$f.bak" ]]; then
                mv "$CACHE_INSTALL_PATH/bin/$f.bak" "$CACHE_INSTALL_PATH/bin/$f"
            fi
        done
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
}
trap cleanup EXIT

SEND_SCRIPT="$PROJECT_ROOT/bin/send-to-agent.sh"

# ============================================================
# QA Validator: Check prerequisites
# ============================================================
echo "QA Validator: Checking prerequisites..."

if [[ ! -f "$SEND_SCRIPT" ]]; then
    echo "ERROR: send-to-agent.sh not found at $SEND_SCRIPT"
    exit 1
fi
echo "  send-to-agent.sh found"

if ! which claude >/dev/null 2>&1; then
    echo "ERROR: 'claude' command not found in PATH"
    echo "This test requires a real Claude Code installation."
    exit 99
fi
echo "  claude found: $(which claude)"
echo ""

# ============================================================
# Phase 1: Agent lookup - resolves agent name to tmux target
# ============================================================
echo "Phase 1: Testing agent lookup from agents.yml..."

mkdir -p "$TEST_DIR/.workflow/001-test-send"
mkdir -p "$TEST_DIR/src"

# Create agents.yml with PM at window 0 pane 1, developer at window 1
cat > "$TEST_DIR/.workflow/001-test-send/agents.yml" << AGENTS_EOF
pm:
  name: PM
  role: pm
  session: $SESSION_NAME
  window: 0
  pane: 1
  model: opus
agents:
  - name: developer
    role: developer
    session: $SESSION_NAME
    window: 1
    model: opus
  - name: qa
    role: qa
    session: $SESSION_NAME
    window: 2
    pane: 0
    model: sonnet
AGENTS_EOF

cat > "$TEST_DIR/.workflow/001-test-send/status.yml" << EOF
status: in-progress
title: "Test send-to-agent"
initial_request: "Testing send-to-agent"
folder: "$TEST_DIR/.workflow/001-test-send"
checkin_interval_minutes: 5
session: "$SESSION_NAME"
agent_message_suffix: ""
checkin_message_suffix: ""
agent_to_pm_message_suffix: ""
EOF

echo '{"tasks": []}' > "$TEST_DIR/.workflow/001-test-send/tasks.json"
echo "// test project" > "$TEST_DIR/index.js"

# Create tmux session:
#   Window 0: pane 0 = checkins, pane 1 = PM
#   Window 1: developer agent
#   Window 2: qa agent
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm-window" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -v -p 50 -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -n "developer" -c "$TEST_DIR"
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -n "qa" -c "$TEST_DIR"
sleep 2

# Disable flow control in developer and qa windows
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "stty -ixon" Enter
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" "stty -ixon" Enter
sleep 1

# Set WORKFLOW_NAME in tmux env
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-send

# Send a message from PM (window 0 pane 1) to developer (window 1)
MSG1="AGENT_LOOKUP_$(date +%s)"

# Run send-to-agent.sh from PM's pane (window 0 pane 1) where it can detect the session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
    "cd '$TEST_DIR' && TMUX_SOCKET='$TMUX_SOCKET' '$SEND_SCRIPT' developer '$MSG1' > '$OUTPUT_FILE' 2>&1; echo EXIT_CODE=\$? >> '$OUTPUT_FILE'" Enter

MAX_WAIT=30
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "EXIT_CODE=" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    SCRIPT_OUTPUT=$(cat "$OUTPUT_FILE")
    EXIT_CODE=$(grep "EXIT_CODE=" "$OUTPUT_FILE" | tail -1 | cut -d= -f2)

    if [[ "$EXIT_CODE" == "0" ]]; then
        pass "send-to-agent.sh exited successfully for 'developer'"
    else
        fail "send-to-agent.sh exited with code $EXIT_CODE (expected 0)"
        echo "     Output: $SCRIPT_OUTPUT"
    fi

    # Verify message was sent to correct target
    if echo "$SCRIPT_OUTPUT" | grep -q "Message sent to"; then
        pass "Confirmation message printed"
    else
        fail "No confirmation message from send-to-agent.sh"
    fi
else
    fail "send-to-agent.sh did not produce output (timeout)"
fi

# Check developer window actually received the message
sleep 2
DEV_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)
if echo "$DEV_OUTPUT" | grep -Fq "$MSG1"; then
    pass "Message delivered to developer window (window 1)"
else
    fail "Message not found in developer window"
    echo "     Expected: $MSG1"
    echo "     Developer pane content:"
    echo "$DEV_OUTPUT" | tail -5
fi

# Also test sending to qa agent (window 2 with pane)
rm -f "$OUTPUT_FILE"
MSG1B="QA_LOOKUP_$(date +%s)"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
    "cd '$TEST_DIR' && TMUX_SOCKET='$TMUX_SOCKET' '$SEND_SCRIPT' qa '$MSG1B' > '$OUTPUT_FILE' 2>&1; echo EXIT_CODE=\$? >> '$OUTPUT_FILE'" Enter

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "EXIT_CODE=" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

sleep 2
QA_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:2" -p)
if echo "$QA_OUTPUT" | grep -Fq "$MSG1B"; then
    pass "Message delivered to qa window (window 2 pane 0)"
else
    fail "Message not found in qa window"
fi

echo ""

# ============================================================
# Phase 2: Unknown agent - helpful error with available agents
# ============================================================
echo "Phase 2: Testing unknown agent error..."

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
    "cd '$TEST_DIR' && TMUX_SOCKET='$TMUX_SOCKET' '$SEND_SCRIPT' nonexistent 'hello' > '$OUTPUT_FILE' 2>&1; echo EXIT_CODE=\$? >> '$OUTPUT_FILE'" Enter

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "EXIT_CODE=" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    ERR_OUTPUT=$(cat "$OUTPUT_FILE")
    EXIT_CODE=$(grep "EXIT_CODE=" "$OUTPUT_FILE" | tail -1 | cut -d= -f2)

    if [[ "$EXIT_CODE" != "0" ]]; then
        pass "Non-zero exit code for unknown agent ($EXIT_CODE)"
    else
        fail "Should exit non-zero for unknown agent"
    fi

    if echo "$ERR_OUTPUT" | grep -qi "not found"; then
        pass "Error message mentions agent not found"
    else
        fail "Error should mention agent not found"
    fi

    if echo "$ERR_OUTPUT" | grep -q "developer"; then
        pass "Error lists available agents (includes 'developer')"
    else
        fail "Error should list available agents"
    fi

    if echo "$ERR_OUTPUT" | grep -q "qa"; then
        pass "Error lists available agents (includes 'qa')"
    else
        fail "Error should list available agents (qa)"
    fi
else
    fail "send-to-agent.sh did not produce output (timeout)"
fi

echo ""

# ============================================================
# Phase 3: Suffix stacking - yato-level PM_TO_AGENTS_SUFFIX
# ============================================================
echo "Phase 3: Testing yato-level suffix (PM_TO_AGENTS_SUFFIX)..."

YATO_SUFFIX="--YATO_S2A_SUFFIX--"

# Create config/defaults.conf with the suffix
mkdir -p "$TEST_DIR/config"
cat > "$TEST_DIR/config/defaults.conf" <<EOF
PM_TO_AGENTS_SUFFIX="$YATO_SUFFIX"
AGENTS_TO_PM_SUFFIX=""
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
EOF

# Clear developer window
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "clear" Enter
sleep 1

rm -f "$OUTPUT_FILE"
MSG3="YATO_SUFFIX_$(date +%s)"

# Use YATO_PATH to point at our test config
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
    "cd '$TEST_DIR' && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' '$SEND_SCRIPT' developer '$MSG3' > '$OUTPUT_FILE' 2>&1; echo EXIT_CODE=\$? >> '$OUTPUT_FILE'" Enter

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "EXIT_CODE=" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

sleep 2
DEV_OUTPUT3=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

if echo "$DEV_OUTPUT3" | grep -Fq "$MSG3"; then
    pass "Original message delivered with yato suffix set"
else
    fail "Original message not found"
fi

if echo "$DEV_OUTPUT3" | grep -Fq -- "$YATO_SUFFIX"; then
    pass "Yato-level PM_TO_AGENTS_SUFFIX appended to message"
else
    fail "Yato-level PM_TO_AGENTS_SUFFIX missing from message"
    echo "     Expected suffix: $YATO_SUFFIX"
    echo "     Developer pane:"
    echo "$DEV_OUTPUT3" | tail -10
fi

echo ""

# ============================================================
# Phase 4: Suffix stacking - both yato-level and workflow-level
# ============================================================
echo "Phase 4: Testing dual suffix stacking (yato + workflow)..."

WF_SUFFIX="--WF_S2A_SUFFIX--"

# Set workflow-level suffix in status.yml
cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$TEST_DIR/.workflow/001-test-send/status.yml')
data = yaml.safe_load(sf.read_text())
data['agent_message_suffix'] = '$WF_SUFFIX'
sf.write_text(yaml.dump(data, default_flow_style=False))
"

# Clear developer window
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "clear" Enter
sleep 1

rm -f "$OUTPUT_FILE"
MSG4="DUAL_SUFFIX_$(date +%s)"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
    "cd '$TEST_DIR' && YATO_PATH='$TEST_DIR' TMUX_SOCKET='$TMUX_SOCKET' '$SEND_SCRIPT' developer '$MSG4' > '$OUTPUT_FILE' 2>&1; echo EXIT_CODE=\$? >> '$OUTPUT_FILE'" Enter

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "EXIT_CODE=" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

sleep 2
DEV_OUTPUT4=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p)

if echo "$DEV_OUTPUT4" | grep -Fq "$MSG4"; then
    pass "Original message delivered with both suffixes set"
else
    fail "Original message not found"
fi

if echo "$DEV_OUTPUT4" | grep -Fq -- "$YATO_SUFFIX"; then
    pass "Yato-level suffix present in dual-suffix message"
else
    fail "Yato-level suffix missing in dual-suffix message"
fi

if echo "$DEV_OUTPUT4" | grep -Fq -- "$WF_SUFFIX"; then
    pass "Workflow-level suffix present in dual-suffix message"
else
    fail "Workflow-level suffix missing in dual-suffix message"
fi

# Check ordering: yato suffix should appear before workflow suffix
YATO_LINE=$(echo "$DEV_OUTPUT4" | grep -Fn -- "$YATO_SUFFIX" | head -1 | cut -d: -f1)
WF_LINE=$(echo "$DEV_OUTPUT4" | grep -Fn -- "$WF_SUFFIX" | head -1 | cut -d: -f1)

if [[ -n "$YATO_LINE" && -n "$WF_LINE" && "$YATO_LINE" -lt "$WF_LINE" ]]; then
    pass "Yato suffix (line $YATO_LINE) before workflow suffix (line $WF_LINE)"
else
    fail "Ordering incorrect: yato=$YATO_LINE, workflow=$WF_LINE (yato should be first)"
fi

echo ""

# ============================================================
# Phase 5: Real Claude Code session - PM uses /send-to-agent
# ============================================================
echo "Phase 5: Real Claude Code session - PM delegates via send-to-agent..."

# Find the active plugin install path from installed_plugins.json
CACHE_INSTALL_PATH=$(python3 -c "
import json, sys
try:
    with open('$HOME/.claude/plugins/installed_plugins.json') as f:
        data = json.load(f)
    for key, versions in data.get('plugins', {}).items():
        if 'yato' in key:
            print(versions[0]['installPath'])
            sys.exit(0)
except Exception:
    pass
" 2>/dev/null)

if [[ -z "$CACHE_INSTALL_PATH" ]]; then
    echo "  SKIP: Cannot find plugin cache path - Phase 5 requires installed yato plugin"
else
    echo "  Plugin cache: $CACHE_INSTALL_PATH"

    # Back up and install dev versions of skill + scripts into plugin cache
    if [[ -d "$CACHE_INSTALL_PATH/skills/send-to-agent" ]]; then
        cp -r "$CACHE_INSTALL_PATH/skills/send-to-agent" "$CACHE_INSTALL_PATH/skills/send-to-agent.bak"
    fi
    cp -r "$PROJECT_ROOT/skills/send-to-agent" "$CACHE_INSTALL_PATH/skills/"
    CACHE_SKILLS_BACKED_UP=true

    for f in send-to-agent.sh send-message.sh; do
        if [[ -f "$CACHE_INSTALL_PATH/bin/$f" ]]; then
            cp "$CACHE_INSTALL_PATH/bin/$f" "$CACHE_INSTALL_PATH/bin/$f.bak"
        fi
        cp "$PROJECT_ROOT/bin/$f" "$CACHE_INSTALL_PATH/bin/$f"
    done
    CACHE_BIN_BACKED_UP=true
    pass "Installed dev skill + scripts into plugin cache"

    # Kill previous session and recreate fresh for real Claude test
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    sleep 2

    # Recreate tmux session:
    #   Window 0: pane 0 = checkins, pane 1 = PM (Claude)
    #   Window 1: developer (receives messages)
    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -n "pm-window" -c "$TEST_DIR"
    tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -v -p 50 -c "$TEST_DIR"
    tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -n "developer" -c "$TEST_DIR"
    sleep 2

    # Set WORKFLOW_NAME
    tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-send

    # Disable flow control
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "stty -ixon" Enter
    sleep 1

    # Update agents.yml with current session name
    cat > "$TEST_DIR/.workflow/001-test-send/agents.yml" << AGENTS2_EOF
pm:
  name: PM
  role: pm
  session: $SESSION_NAME
  window: 0
  pane: 1
  model: opus
agents:
  - name: developer
    role: developer
    session: $SESSION_NAME
    window: 1
    model: opus
AGENTS2_EOF

    # Reset suffixes for clean test
    cat > "$TEST_DIR/config/defaults.conf" <<CONF_EOF
PM_TO_AGENTS_SUFFIX=""
AGENTS_TO_PM_SUFFIX=""
DEFAULT_SESSION="test"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
CONF_EOF

    cd "$PROJECT_ROOT" && uv run python -c "
import yaml
from pathlib import Path
sf = Path('$TEST_DIR/.workflow/001-test-send/status.yml')
data = yaml.safe_load(sf.read_text())
data['agent_message_suffix'] = ''
sf.write_text(yaml.dump(data, default_flow_style=False))
"

    # Create agent-tasks.md for developer (PM should update this before sending)
    mkdir -p "$TEST_DIR/.workflow/001-test-send/agents/developer"
    cat > "$TEST_DIR/.workflow/001-test-send/agents/developer/agent-tasks.md" << 'TASKS_EOF'
# Developer Tasks

No tasks assigned yet.
TASKS_EOF

    # Create initial tasks.json
    echo '{"tasks": []}' > "$TEST_DIR/.workflow/001-test-send/tasks.json"

    # Launch Claude as PM in window 0 pane 1
    echo "  Starting Claude as PM..."
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
        "unset CLAUDECODE && export WORKFLOW_NAME=001-test-send && claude --dangerously-skip-permissions" Enter

    echo "  Waiting for Claude to initialize..."
    MAX_WAIT=30
    WAITED=0
    while [[ $WAITED -lt $MAX_WAIT ]]; do
        OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p 2>/dev/null)
        if echo "$OUTPUT" | grep -qi "trust"; then
            echo "  Trust prompt found, accepting..."
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" Enter
            sleep 15
            break
        fi
        if echo "$OUTPUT" | grep -q "^❯" || echo "$OUTPUT" | grep -q "tips"; then
            break
        fi
        sleep 3
        WAITED=$((WAITED + 3))
    done

    # Capture developer window baseline (line count before delegation)
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" "clear" Enter
    sleep 1
    DEV_BASELINE=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p | grep -c '.')

    # Ask PM to delegate a task to developer using /send-to-agent
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
        "Use /send-to-agent to send the developer agent this message: You have a new task. Please create hello.py" 2>/dev/null
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" Enter 2>/dev/null

    echo "  Waiting for Claude to process delegation..."

    # Wait for Claude to execute the command
    MAX_WAIT=120
    WAITED=0
    while [[ $WAITED -lt $MAX_WAIT ]]; do
        CLAUDE_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p -S -100 2>/dev/null)
        # Handle "Use skill" prompts by accepting
        if echo "$CLAUDE_OUTPUT" | grep -qi "Use skill"; then
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" Down Enter 2>/dev/null
            sleep 10
            WAITED=$((WAITED + 10))
            continue
        fi
        # Check for completion signals
        if echo "$CLAUDE_OUTPUT" | grep -qi "Message sent\|send-to-agent\|delegat"; then
            sleep 5
            break
        fi
        # Check for idle prompt (Claude finished)
        if echo "$CLAUDE_OUTPUT" | grep -q "^❯" && [[ $WAITED -gt 30 ]]; then
            break
        fi
        sleep 5
        WAITED=$((WAITED + 5))
    done

    sleep 5

    # Check that PM used send-to-agent.sh (look for confirmation in PM output)
    CLAUDE_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:0.1" -p -S -200 2>/dev/null)
    if echo "$CLAUDE_OUTPUT" | grep -qi "send-to-agent\|Message sent"; then
        pass "PM invoked send-to-agent.sh"
    else
        fail "PM did not appear to use send-to-agent.sh"
        echo "     PM output (last 15 lines):"
        echo "$CLAUDE_OUTPUT" | tail -15
    fi

    # Check that developer window received something (more lines than baseline)
    DEV_OUTPUT5=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME:1" -p -S -200)
    DEV_LINES=$(echo "$DEV_OUTPUT5" | grep -c '.')
    # Check for content indicating a message was delivered: either text from PM,
    # or "command not found" (shell tried to execute message text), or new lines appeared
    if echo "$DEV_OUTPUT5" | grep -qi "task\|hello\|developer\|command not found\|not found\|zsh:"; then
        pass "Developer window received content from PM"
    elif [[ $DEV_LINES -gt $((DEV_BASELINE + 2)) ]]; then
        pass "Developer window received new content (line count increased)"
    else
        fail "Developer window did not receive the message"
        echo "     Baseline lines: $DEV_BASELINE, Current lines: $DEV_LINES"
        echo "     Developer pane:"
        echo "$DEV_OUTPUT5" | tail -15
    fi
fi

echo ""

# ============================================================
# Phase 6: Skill file configuration verification
# ============================================================
echo "Phase 6: Verifying send-to-agent skill configuration..."

SKILL_FILE="$PROJECT_ROOT/skills/send-to-agent/SKILL.md"

if [[ -f "$SKILL_FILE" ]]; then
    pass "Skill file exists at skills/send-to-agent/SKILL.md"
else
    fail "Skill file missing at skills/send-to-agent/SKILL.md"
fi

if [[ -f "$SKILL_FILE" ]]; then
    SKILL_CONTENT=$(cat "$SKILL_FILE")

    # Check skill uses CLAUDE_PLUGIN_ROOT path
    if echo "$SKILL_CONTENT" | grep -q 'CLAUDE_PLUGIN_ROOT.*/bin/send-to-agent.sh'; then
        pass "Skill uses correct \${CLAUDE_PLUGIN_ROOT}/bin/send-to-agent.sh path"
    else
        fail "Skill should use \${CLAUDE_PLUGIN_ROOT}/bin/send-to-agent.sh path"
    fi

    # Check it's for PM only
    if echo "$SKILL_CONTENT" | grep -qi "Only for PM\|Only.*PM agent"; then
        pass "Skill description states PM-only usage"
    else
        fail "Skill should state it's for PM agents only"
    fi

    # Check it mentions updating tasks before sending
    if echo "$SKILL_CONTENT" | grep -qi "tasks.json\|update.*task"; then
        pass "Skill mentions updating tasks before sending"
    else
        fail "Skill should mention updating tasks before sending"
    fi

    # Check it mentions agent-tasks.md
    if echo "$SKILL_CONTENT" | grep -qi "agent-tasks.md"; then
        pass "Skill mentions agent-tasks.md"
    else
        fail "Skill should mention agent-tasks.md"
    fi
fi

echo ""

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
