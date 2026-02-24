#!/bin/bash
# test-pm-file-access-workflow-detection.sh
#
# E2E Test: PM file access guard via workflow-based role detection (agents.yml)
#
# This test verifies that the pm-file-access-guard hook detects the PM role
# by matching the current tmux window/pane against agents.yml.
#
# This is the detection path in production: Claude Code runs in a
# tmux pane, the hook reads agents.yml to find which agent is in that pane.
#
# Phases:
# 1. Hook configuration verification
# 2. Setup test environment (project with .workflow/agents.yml)
# 3. Direct: PM detected via agents.yml from PM's tmux pane (window 0 pane 0)
# 4. Direct: PM allowed to edit workflow files via agents.yml detection
# 5. Direct: Developer detected from developer's tmux window (window 1)
# 6. Direct: No match = no role = allowed (window with no agent)
# 7. Real Claude session: PM blocked from editing source code via workflow detection

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(cd "$SCRIPT_DIR/../.." && pwd)"
TEST_NAME="pm-access-workflow"
TEST_ID="$$"
TEST_DIR="/tmp/e2e-test-$TEST_NAME-$TEST_ID"
SESSION_NAME="e2e-wf-access-$TEST_ID"
export TMUX_SOCKET="yato-e2e-test"
OUTPUT_FILE="/tmp/e2e-hook-output-$TEST_ID"

echo "======================================================================"
echo "  E2E Test: PM File Access Guard - Workflow Detection (agents.yml)"
echo "======================================================================"
echo ""

TESTS_PASSED=0
TESTS_FAILED=0

pass() { echo "  PASS: $1"; TESTS_PASSED=$((TESTS_PASSED + 1)); }
fail() { echo "  FAIL: $1"; TESTS_FAILED=$((TESTS_FAILED + 1)); }

cleanup() {
    echo ""; echo "Cleaning up..."
    # Restore cached hooks if we replaced them
    if [[ -n "$CACHE_HOOK_DIR" && -f "$CACHE_HOOK_DIR/pm-file-access-guard.py.bak" ]]; then
        mv "$CACHE_HOOK_DIR/pm-file-access-guard.py.bak" "$CACHE_HOOK_DIR/pm-file-access-guard.py"
    fi
    if [[ -n "$CACHE_HOOK_DIR" && -f "$CACHE_HOOK_DIR/role_detection.py.bak" ]]; then
        mv "$CACHE_HOOK_DIR/role_detection.py.bak" "$CACHE_HOOK_DIR/role_detection.py"
    fi
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    rm -rf "$TEST_DIR" 2>/dev/null || true
    rm -f "$OUTPUT_FILE" 2>/dev/null || true
}
# Pre-initialize CACHE_HOOK_DIR so cleanup trap can reference it
CACHE_HOOK_DIR=""
trap cleanup EXIT

HOOK_SCRIPT="$PROJECT_ROOT/hooks/scripts/pm-file-access-guard.py"

# ============================================================
# Phase 1: Verify hook script exists
# ============================================================
echo "Phase 1: Checking hook configuration..."

if [[ -f "$HOOK_SCRIPT" ]]; then
    pass "Hook script exists"
else
    fail "Hook script not found at $HOOK_SCRIPT"
    exit 1
fi

echo ""

# ============================================================
# Phase 2: Setup test environment
# ============================================================
echo "Phase 2: Setting up test environment..."

mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/pm"
mkdir -p "$TEST_DIR/.workflow/001-test-workflow/agents/developer"
mkdir -p "$TEST_DIR/src"

# Create tmux session first so we can capture pane IDs for identity.yml
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow

# Capture the default pane ID (window 0 pane 0 = PM for initial test)
PM_PANE_ID=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F '#{pane_id}' | head -1)

# Create agents.yml with pane_id (primary routing identifier)
cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << EOF
pm:
  name: PM
  role: pm
  pane_id: "$PM_PANE_ID"
  session: $SESSION_NAME
  window: 0
  model: opus
agents:
  - name: developer
    role: developer
    pane_id: ""
    session: $SESSION_NAME
    window: 1
    model: opus
EOF

# Create identity.yml files with pane_id (used by role detection)
cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_ID"
window: 0
workflow: 001-test-workflow
can_modify_code: false
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/developer/identity.yml" << EOF
name: developer
role: developer
model: opus
pane_id:
window: 1
workflow: 001-test-workflow
can_modify_code: true
EOF

# Create workflow status
echo 'status: in-progress' > "$TEST_DIR/.workflow/001-test-workflow/status.yml"

# Create workflow files (should be allowed for PM)
echo '{"tasks": []}' > "$TEST_DIR/.workflow/001-test-workflow/tasks.json"
echo '# Test PRD' > "$TEST_DIR/.workflow/001-test-workflow/prd.md"

# Create source files (should be blocked for PM)
echo 'print("Hello")' > "$TEST_DIR/src/main.py"
echo '{}' > "$TEST_DIR/package.json"

pass "Test directory created at $TEST_DIR"
echo ""

# ============================================================
# Phase 3: PM detected via pane_id from PM's tmux pane
# ============================================================
echo "Phase 3: Testing PM detected via pane_id..."

# Run the hook from inside the tmux pane (window 0 pane 0 = PM)
# Run hook from inside the tmux pane - detection comes from agents.yml pane matching
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

# Wait for hook to complete
MAX_WAIT=30
WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"block"'; then
        pass "PM detected via agents.yml - blocked from src/main.py"
    else
        fail "PM should be blocked from src/main.py (got: $HOOK_OUTPUT)"
    fi

    if echo "$HOOK_OUTPUT" | grep -qi "PM FILE ACCESS DENIED"; then
        pass "Block message contains 'PM FILE ACCESS DENIED'"
    else
        fail "Block message should contain 'PM FILE ACCESS DENIED'"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

echo ""

# ============================================================
# Phase 3b: Production layout - PM at pane 1 (split window)
# ============================================================
echo "Phase 3b: Testing PM detection at pane 1 (production layout)..."

# Split window 0 to create pane 1 (production layout: pane 0 = checkins, pane 1 = PM)
PM_PANE_1_ID=$(tmux -L "$TMUX_SOCKET" split-window -t "$SESSION_NAME:0" -c "$TEST_DIR" -P -F '#{pane_id}' 2>/dev/null)
sleep 2

# Update agents.yml and identity.yml with the new PM pane_id
cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << EOF
pm:
  name: PM
  role: pm
  pane_id: "$PM_PANE_1_ID"
  session: $SESSION_NAME
  window: 0
  model: opus
agents:
  - name: developer
    role: developer
    pane_id: ""
    session: $SESSION_NAME
    window: 1
    model: opus
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_1_ID"
window: 0
workflow: 001-test-workflow
can_modify_code: false
EOF

rm -f "$OUTPUT_FILE"

# Run hook from pane 1 of window 0 (PM's actual pane in production)
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.1" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"block"'; then
        pass "PM detected at pane 1 (production layout) - blocked from src/main.py"
    else
        fail "PM at pane 1 should be blocked from src/main.py (got: $HOOK_OUTPUT)"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

# Verify pane 0 of window 0 is NOT detected as PM (pane_id detection is pane-specific, not window-level)
rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:0.0" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
        pass "Pane 0 of window 0 NOT detected as PM (pane_id is pane-specific)"
    else
        fail "Pane 0 should not match PM since pane_id detection is pane-specific (got: $HOOK_OUTPUT)"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

# Kill session and recreate clean (with single pane) for remaining tests
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
sleep 1
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null
tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow

# Update PM identity.yml with new pane_id after session recreation
PM_PANE_RECREATED=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F '#{pane_id}' | head -1)
cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << EOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_RECREATED"
window: 0
workflow: 001-test-workflow
can_modify_code: false
EOF

cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << EOF
pm:
  name: PM
  role: pm
  pane_id: "$PM_PANE_RECREATED"
  session: $SESSION_NAME
  window: 0
  model: opus
agents:
  - name: developer
    role: developer
    pane_id: ""
    session: $SESSION_NAME
    window: 1
    model: opus
EOF

echo ""

# ============================================================
# Phase 4: PM allowed to edit workflow files via agents.yml
# ============================================================
echo "Phase 4: Testing PM allowed to edit workflow files via agents.yml..."

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/tasks.json\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
        pass "PM allowed to edit tasks.json via agents.yml detection"
    else
        fail "PM should be allowed to edit tasks.json (got: $HOOK_OUTPUT)"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

# Test prd.md
rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/.workflow/001-test-workflow/prd.md\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
        pass "PM allowed to edit prd.md via agents.yml detection"
    else
        fail "PM should be allowed to edit prd.md (got: $HOOK_OUTPUT)"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

echo ""

# ============================================================
# Phase 5: Developer detected from developer's tmux window
# ============================================================
echo "Phase 5: Testing developer detected via pane_id from window 1..."

# Create window 1 and capture its pane_id
DEV_PANE_ID=$(tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" -P -F '#{pane_id}' 2>/dev/null)
sleep 3

# Update developer identity.yml with actual pane_id
cat > "$TEST_DIR/.workflow/001-test-workflow/agents/developer/identity.yml" << EOF
name: developer
role: developer
model: opus
pane_id: "$DEV_PANE_ID"
window: 1
workflow: 001-test-workflow
can_modify_code: true
EOF

rm -f "$OUTPUT_FILE"

# Run hook from window 1 (which maps to developer in agents.yml)
# Developer should be allowed to edit any file
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:1" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
        pass "Developer (window 1) allowed to edit src/main.py"
    else
        fail "Developer should be allowed to edit src/main.py (got: $HOOK_OUTPUT)"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

echo ""

# ============================================================
# Phase 6: No match = no role = allowed
# ============================================================
echo "Phase 6: Testing unmatched window (no agent) has full access..."

# Create window 2 (not in agents.yml - no agent mapped here)
tmux -L "$TMUX_SOCKET" new-window -d -t "$SESSION_NAME" -c "$TEST_DIR" 2>/dev/null
sleep 3

rm -f "$OUTPUT_FILE"

tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME:2" \
    "echo '{\"tool_input\":{\"file_path\":\"$TEST_DIR/src/main.py\"}}' | WORKFLOW_NAME=001-test-workflow TMUX_SOCKET='$TMUX_SOCKET' uv run --directory '$PROJECT_ROOT' python '$HOOK_SCRIPT' > '$OUTPUT_FILE' 2>&1 && echo HOOK_DONE >> '$OUTPUT_FILE'" Enter 2>/dev/null

WAITED=0
while [[ $WAITED -lt $MAX_WAIT ]]; do
    if [[ -f "$OUTPUT_FILE" ]] && grep -q "HOOK_DONE" "$OUTPUT_FILE" 2>/dev/null; then
        break
    fi
    sleep 1
    WAITED=$((WAITED + 1))
done

if [[ -f "$OUTPUT_FILE" ]]; then
    HOOK_OUTPUT=$(cat "$OUTPUT_FILE")
    if echo "$HOOK_OUTPUT" | grep -q '"continue": true\|"continue":true'; then
        pass "Unmatched window allowed to edit src/main.py"
    else
        fail "Unmatched window should be allowed (no role detected) (got: $HOOK_OUTPUT)"
    fi
else
    fail "Hook did not produce output (timeout)"
fi

echo ""

# ============================================================
# Phase 7: Real Claude session - PM blocked via workflow detection
# ============================================================
echo "Phase 7: Real Claude session - PM blocked via workflow detection..."

# Claude Code loads hooks from the installed plugin cache, not the dev directory.
# Temporarily install the dev version of the hook into the cache.
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
CACHE_HOOK_DIR="${CACHE_INSTALL_PATH:+$CACHE_INSTALL_PATH/hooks/scripts}"
if [[ -n "$CACHE_HOOK_DIR" && -f "$CACHE_HOOK_DIR/pm-file-access-guard.py" ]]; then
    cp "$CACHE_HOOK_DIR/pm-file-access-guard.py" "$CACHE_HOOK_DIR/pm-file-access-guard.py.bak"
    cp "$HOOK_SCRIPT" "$CACHE_HOOK_DIR/pm-file-access-guard.py"
    # Also copy the shared role_detection module
    ROLE_DETECTION_SRC="$PROJECT_ROOT/hooks/scripts/role_detection.py"
    if [[ -f "$ROLE_DETECTION_SRC" ]]; then
        if [[ -f "$CACHE_HOOK_DIR/role_detection.py" ]]; then
            cp "$CACHE_HOOK_DIR/role_detection.py" "$CACHE_HOOK_DIR/role_detection.py.bak"
        fi
        cp "$ROLE_DETECTION_SRC" "$CACHE_HOOK_DIR/role_detection.py"
    fi
    RESTORE_CACHE=true
    pass "Installed dev hook into plugin cache"
else
    echo "  SKIP: Cannot find plugin cache hook directory - Phase 7 requires installed plugin"
    RESTORE_CACHE=false
fi

if [[ "$RESTORE_CACHE" == true ]]; then
    # Kill previous session and recreate
    tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME" 2>/dev/null || true
    sleep 2

    # Create fresh session at window 0 pane 0 (PM's pane per agents.yml)
    tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -x 120 -y 40 -c "$TEST_DIR" 2>/dev/null

    # Set WORKFLOW_NAME in tmux env (standard in yato sessions)
    tmux -L "$TMUX_SOCKET" setenv -t "$SESSION_NAME" WORKFLOW_NAME 001-test-workflow

    # Capture fresh PM pane_id and update identity.yml + agents.yml
    PM_PANE_P7=$(tmux -L "$TMUX_SOCKET" list-panes -t "$SESSION_NAME:0" -F '#{pane_id}' | head -1)
    cat > "$TEST_DIR/.workflow/001-test-workflow/agents/pm/identity.yml" << IDEOF
name: PM
role: pm
model: opus
pane_id: "$PM_PANE_P7"
window: 0
workflow: 001-test-workflow
can_modify_code: false
IDEOF
    cat > "$TEST_DIR/.workflow/001-test-workflow/agents.yml" << AGEOF
pm:
  name: PM
  role: pm
  pane_id: "$PM_PANE_P7"
  session: $SESSION_NAME
  window: 0
  model: opus
agents:
  - name: developer
    role: developer
    pane_id: ""
    session: $SESSION_NAME
    window: 1
    model: opus
AGEOF

    # Unset CLAUDECODE to allow nested Claude launch (when test runs from within Claude Code)
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "unset CLAUDECODE && export WORKFLOW_NAME=001-test-workflow && claude --dangerously-skip-permissions" Enter 2>/dev/null

    echo "  Waiting for Claude to initialize..."

    # Wait for Claude to start
    MAX_WAIT=30
    WAITED=0
    while [[ $WAITED -lt $MAX_WAIT ]]; do
        OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p 2>/dev/null)
        if echo "$OUTPUT" | grep -qi "trust"; then
            echo "  Trust prompt found, accepting..."
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter 2>/dev/null
            sleep 15
            break
        fi
        if echo "$OUTPUT" | grep -q "^❯"; then
            break
        fi
        sleep 3
        WAITED=$((WAITED + 3))
    done

    # Ask Claude to write a source file (should be blocked by hook)
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" \
        "Write the text 'hello world' to the file $TEST_DIR/src/main.py using the Write tool. Do not ask for clarification, just write." 2>/dev/null
    sleep 1
    tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Enter 2>/dev/null

    echo "  Waiting for Claude to process..."

    # Wait for block message or completion
    MAX_WAIT=90
    WAITED=0
    FOUND=false
    while [[ $WAITED -lt $MAX_WAIT ]]; do
        CLAUDE_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)
        # Handle "Use skill" prompts by selecting the second option
        if echo "$CLAUDE_OUTPUT" | grep -qi "Use skill"; then
            tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" Down Enter 2>/dev/null
        fi
        if echo "$CLAUDE_OUTPUT" | grep -qi "PM FILE ACCESS DENIED\|delegate.*agent\|PM.*NOT allowed"; then
            FOUND=true
            break
        fi
        # Check for the idle prompt (Claude finished without block - bad)
        if echo "$CLAUDE_OUTPUT" | grep -q "^❯" && [[ $WAITED -gt 20 ]]; then
            break
        fi
        sleep 5
        WAITED=$((WAITED + 5))
    done

    CLAUDE_OUTPUT=$(tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -100 2>/dev/null)

    if [[ "$FOUND" == true ]] || echo "$CLAUDE_OUTPUT" | grep -qi "PM FILE ACCESS DENIED\|delegate.*agent\|PM.*NOT allowed"; then
        pass "Real Claude session: PM blocked from writing source file via workflow detection"
    else
        fail "Real Claude session: PM should be blocked (detection via agents.yml)"
    fi

    # Restore the original cached hooks
    if [[ -f "$CACHE_HOOK_DIR/pm-file-access-guard.py.bak" ]]; then
        mv "$CACHE_HOOK_DIR/pm-file-access-guard.py.bak" "$CACHE_HOOK_DIR/pm-file-access-guard.py"
    fi
    if [[ -f "$CACHE_HOOK_DIR/role_detection.py.bak" ]]; then
        mv "$CACHE_HOOK_DIR/role_detection.py.bak" "$CACHE_HOOK_DIR/role_detection.py"
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
