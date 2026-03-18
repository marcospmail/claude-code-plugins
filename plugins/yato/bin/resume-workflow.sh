#!/bin/bash
# resume-workflow.sh - Resume a workflow by restoring session, PM, and all agents
#
# Usage: ./resume-workflow.sh <project-path> [workflow-name]
#
# If workflow-name is not provided, lists available workflows
# If workflow-name is provided, resumes that workflow
#
# This script PROGRAMMATICALLY restores:
# 1. Creates/uses tmux session
# 2. Sets up pane layout (Check-ins | PM | Agents)
# 3. Starts Claude in PM pane with correct model
# 4. Recreates ALL agent panes from identity.yml files
# 5. Starts Claude in EACH agent pane with correct model
# 6. Re-enables ralph loop if it was active

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source workflow utilities
source "$SCRIPT_DIR/workflow-utils.sh"

# Support isolated tmux socket (used by e2e tests)
# Normal use: TMUX_SOCKET unset → TMUX_FLAGS="" → bare tmux (unchanged)
# Tests:      TMUX_SOCKET="yato-e2e-test" → TMUX_FLAGS="-L yato-e2e-test" (isolated)
TMUX_FLAGS="${TMUX_SOCKET:+-L $TMUX_SOCKET}"

# Parse arguments
PROJECT_PATH="${1:-}"
WORKFLOW_NAME="${2:-}"

print_usage() {
    cat << 'EOF'
Resume Workflow Script

USAGE:
  resume-workflow.sh <project-path>                    # List available workflows
  resume-workflow.sh <project-path> <workflow-name>    # Resume specific workflow

ARGUMENTS:
  project-path     Path to the project directory
  workflow-name    Name of workflow to resume (e.g., "001-add-user-auth")

EXAMPLES:
  resume-workflow.sh ~/projects/myapp                  # List workflows
  resume-workflow.sh ~/projects/myapp 001-add-auth     # Resume workflow

WHAT IT DOES:
  1. Creates tmux session (or uses current one if inside tmux)
  2. Sets up pane layout: Check-ins | PM | Agents
  3. Starts Claude with correct model in PM pane
  4. Recreates ALL agent panes from saved identity.yml files
  5. Starts Claude with correct model in EACH agent pane
  6. Re-enables ralph loop if it was previously active
EOF
}

# Validate project path
if [[ -z "$PROJECT_PATH" ]]; then
    print_usage
    exit 1
fi

# Expand project path
PROJECT_PATH=$(eval echo "$PROJECT_PATH")

if [[ ! -d "$PROJECT_PATH" ]]; then
    echo "Error: Project path does not exist: $PROJECT_PATH"
    exit 1
fi

# If no workflow specified, list available workflows
if [[ -z "$WORKFLOW_NAME" ]]; then
    echo "Available workflows in $PROJECT_PATH:"
    echo ""
    list_workflows "$PROJECT_PATH"
    echo ""
    echo "To resume a workflow, run:"
    echo "  $0 $PROJECT_PATH <workflow-name>"
    exit 0
fi

# Verify the workflow exists
WORKFLOW_PATH="$PROJECT_PATH/.workflow/$WORKFLOW_NAME"
if [[ ! -d "$WORKFLOW_PATH" ]]; then
    echo "Error: Workflow not found: $WORKFLOW_NAME"
    echo ""
    echo "Available workflows:"
    list_workflows "$PROJECT_PATH"
    exit 1
fi

# Read workflow info from status.yml
STATUS_FILE="$WORKFLOW_PATH/status.yml"
if [[ -f "$STATUS_FILE" ]]; then
    WORKFLOW_TITLE=$(grep "^title:" "$STATUS_FILE" | sed 's/title: //' | tr -d '"')
    WORKFLOW_STATUS=$(grep "^status:" "$STATUS_FILE" | sed 's/status: //')
    CHECKIN_INTERVAL=$(grep "^checkin_interval_minutes:" "$STATUS_FILE" | sed 's/checkin_interval_minutes: //')
else
    WORKFLOW_TITLE="Unknown"
    WORKFLOW_STATUS="unknown"
    CHECKIN_INTERVAL="15"
fi

echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              RESUMING WORKFLOW: $WORKFLOW_NAME"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Title: $WORKFLOW_TITLE"
echo "Status: $WORKFLOW_STATUS"
echo "Check-in interval: ${CHECKIN_INTERVAL} minutes"
echo ""

# Always create a dedicated workflow session (matching deploy behavior)
# The deploy creates: ${PROJECT_SLUG}_${WORKFLOW_NAME}
# Resume must use the same naming to avoid reusing the orchestrator's session.
PROJECT_SLUG=$(basename "$PROJECT_PATH" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')
SESSION="${PROJECT_SLUG}_${WORKFLOW_NAME}"

IN_TMUX=false
if [[ -n "$TMUX" ]]; then
    IN_TMUX=true
fi

if tmux $TMUX_FLAGS has-session -t "$SESSION" 2>/dev/null; then
    echo "Reusing existing workflow session: $SESSION"
else
    echo "Creating workflow session: $SESSION"
    tmux $TMUX_FLAGS new-session -d -s "$SESSION" -c "$PROJECT_PATH"
fi

# Update session in status.yml directly (not using current file)
if [[ -f "$STATUS_FILE" ]]; then
    sed -i '' "s/^session: .*/session: \"$SESSION\"/" "$STATUS_FILE"
fi

# CRITICAL: Set WORKFLOW_NAME in tmux environment for other scripts
tmux $TMUX_FLAGS setenv -t "$SESSION" WORKFLOW_NAME "$WORKFLOW_NAME"

# Rename window 0 to "Orchestrator" (matches init behavior from orchestrator.py)
tmux $TMUX_FLAGS rename-window -t "$SESSION:0" "Orchestrator"

# Enable pane titles display
tmux $TMUX_FLAGS set-option -t "$SESSION" pane-border-status top
tmux $TMUX_FLAGS set-option -t "$SESSION" pane-border-format " #{pane_title} "

# Check if we have a saved layout
LAYOUT_FILE="$WORKFLOW_PATH/layout.yml"

# Set up the PM pane layout
# Layout: Check-ins (top, small) + PM (bottom, large)
# Agents are created in separate windows
echo ""
echo "Setting up pane layout..."

PANE_COUNT=$(tmux $TMUX_FLAGS list-panes -t "$SESSION:0" 2>/dev/null | wc -l | tr -d ' ')

if [[ "$PANE_COUNT" -lt 2 ]]; then
    # Start fresh - create the layout
    # Split vertically - Check-ins on top (20% height)
    tmux $TMUX_FLAGS split-window -t "$SESSION:0.0" -v -b -p 20 -c "$PROJECT_PATH"
    # Now: pane 0 = Check-ins, pane 1 = PM

    tmux $TMUX_FLAGS select-pane -t "$SESSION:0.0" -T "Check-ins"
    tmux $TMUX_FLAGS set-option -p -t "$SESSION:0.0" allow-set-title off

    tmux $TMUX_FLAGS select-pane -t "$SESSION:0.1" -T "PM"
    tmux $TMUX_FLAGS set-option -p -t "$SESSION:0.1" allow-set-title off
fi

# Capture global pane IDs for check-ins and PM
CHECKINS_PANE_ID=$(tmux $TMUX_FLAGS display-message -t "$SESSION:0.0" -p '#{pane_id}' 2>/dev/null)
PM_PANE_ID=$(tmux $TMUX_FLAGS display-message -t "$SESSION:0.1" -p '#{pane_id}' 2>/dev/null)
CHECKINS_PANE="${CHECKINS_PANE_ID:-$SESSION:0.0}"
PM_PANE="${PM_PANE_ID:-$SESSION:0.1}"

echo "  Check-ins: $SESSION:0.0"
echo "  PM: $PM_PANE"
echo "  Agents will be created in separate windows"

# Collect agents to restore from agents.yml (source of truth for windows)
AGENTS_FILE="$WORKFLOW_PATH/agents.yml"
declare -a AGENT_NAMES
declare -a AGENT_ROLES
declare -a AGENT_MODELS
declare -a AGENT_WINDOWS

if [[ -f "$AGENTS_FILE" ]]; then
    # Parse agents from agents.yml using Python for reliable YAML parsing
    eval "$(uv run python -c "
import sys
try:
    with open('$AGENTS_FILE', 'r') as f:
        content = f.read()

    # Simple YAML parsing for agents section
    in_agents = False
    current_agent = {}
    agents = []

    for line in content.split('\n'):
        line = line.rstrip()
        if line.startswith('agents:'):
            in_agents = True
            continue
        if in_agents and line.startswith('  - name:'):
            if current_agent:
                agents.append(current_agent)
            current_agent = {'name': line.split(':')[1].strip()}
        elif in_agents and line.startswith('    '):
            key, _, value = line.strip().partition(':')
            current_agent[key.strip()] = value.strip().strip('\"')

    if current_agent and 'name' in current_agent:
        agents.append(current_agent)

    # Output bash array assignments
    names = []
    roles = []
    models = []
    windows = []
    for a in agents:
        if a.get('name'):
            names.append(a.get('name', ''))
            roles.append(a.get('role', ''))
            models.append(a.get('model', 'sonnet'))
            windows.append(a.get('window', '1'))

    print('AGENT_NAMES=(' + ' '.join(['\"' + n + '\"' for n in names]) + ')')
    print('AGENT_ROLES=(' + ' '.join(['\"' + r + '\"' for r in roles]) + ')')
    print('AGENT_MODELS=(' + ' '.join(['\"' + m + '\"' for m in models]) + ')')
    print('AGENT_WINDOWS=(' + ' '.join(['\"' + w + '\"' for w in windows]) + ')')
except Exception as e:
    print(f'# Error parsing agents.yml: {e}', file=sys.stderr)
    print('AGENT_NAMES=()')
    print('AGENT_ROLES=()')
    print('AGENT_MODELS=()')
    print('AGENT_WINDOWS=()')
")"
fi

AGENT_COUNT=${#AGENT_NAMES[@]}
echo ""
echo "Found $AGENT_COUNT agents to restore:"
for i in "${!AGENT_NAMES[@]}"; do
    echo "  - ${AGENT_NAMES[$i]} (${AGENT_ROLES[$i]}, model: ${AGENT_MODELS[$i]}, window: ${AGENT_WINDOWS[$i]})"
done

# Create agent windows (each agent gets its own window with correct number)
echo ""
echo "Restoring agent windows..."

declare -a AGENT_IDS
declare -a AGENT_PANE_IDS

for i in "${!AGENT_NAMES[@]}"; do
    agent_name="${AGENT_NAMES[$i]}"
    agent_role="${AGENT_ROLES[$i]}"
    agent_model="${AGENT_MODELS[$i]}"
    agent_window="${AGENT_WINDOWS[$i]}"

    echo "  Creating window $agent_window for: $agent_name ($agent_role, $agent_model)"

    # Create new window for this agent with specific window name
    # Capture both window index and global pane ID
    WINDOW_OUTPUT=$(tmux $TMUX_FLAGS new-window -t "$SESSION" -n "$agent_name" -c "$PROJECT_PATH" -P -F "#{session_name}:#{window_index}:#{pane_id}" 2>&1)

    if [[ $? -ne 0 ]] || [[ -z "$WINDOW_OUTPUT" ]]; then
        echo "    Warning: Could not create window for $agent_name"
        AGENT_IDS+=("")
        AGENT_PANE_IDS+=("")
        continue
    fi

    # Parse output: session:window_index:pane_id
    AGENT_WINDOW="${WINDOW_OUTPUT%:*}"  # session:window_index
    AGENT_PANE_ID="${WINDOW_OUTPUT##*:}"  # %N pane ID

    # Start Claude with correct model and bypass permissions
    sleep 0.3
    tmux $TMUX_FLAGS send-keys -t "$AGENT_PANE_ID" "claude --dangerously-skip-permissions --model $agent_model" Enter

    # Store agent ID and pane ID
    AGENT_IDS+=("$AGENT_WINDOW")
    AGENT_PANE_IDS+=("$AGENT_PANE_ID")

    # Update identity.yml with new pane_id and window info
    AGENTS_DIR="$WORKFLOW_PATH/agents"
    # Try by agent name first, then by role
    IDENTITY_FILE="$AGENTS_DIR/$agent_name/identity.yml"
    if [[ ! -f "$IDENTITY_FILE" ]]; then
        IDENTITY_FILE="$AGENTS_DIR/$agent_role/identity.yml"
    fi
    if [[ -f "$IDENTITY_FILE" ]]; then
        # Update pane_id if field exists, otherwise append it
        if grep -q "^pane_id:" "$IDENTITY_FILE"; then
            sed -i '' "s|^pane_id:.*|pane_id: \"$AGENT_PANE_ID\"|" "$IDENTITY_FILE"
        else
            echo "pane_id: \"$AGENT_PANE_ID\"" >> "$IDENTITY_FILE"
        fi
        new_window="${AGENT_WINDOW##*:}"
        sed -i '' "s|^window:.*|window: $new_window|" "$IDENTITY_FILE"
        # Update session field if present (for legacy identity.yml files)
        if grep -q "^session:" "$IDENTITY_FILE"; then
            sed -i '' "s|^session:.*|session: \"$SESSION\"|" "$IDENTITY_FILE"
        fi
    fi
done

# Start checkin-display.sh in the check-ins pane
echo ""
echo "Starting check-in display..."
tmux $TMUX_FLAGS send-keys -t "$CHECKINS_PANE" "$SCRIPT_DIR/checkin-display.sh" Enter

# Restart check-in daemon if there are incomplete tasks and no daemon running
echo ""
echo "Checking check-in daemon status..."
DAEMON_STATUS=$(cd "$PROJECT_PATH" && uv run --project "$SCRIPT_DIR/.." python "$SCRIPT_DIR/../lib/checkin_scheduler.py" status --workflow "$WORKFLOW_NAME" 2>&1)
DAEMON_RUNNING=$(echo "$DAEMON_STATUS" | grep "Daemon running:" | grep -c "True" || true)
INCOMPLETE_TASKS=$(echo "$DAEMON_STATUS" | grep "Incomplete tasks:" | awk '{print $NF}')

if [[ "$DAEMON_RUNNING" == "0" && -n "$INCOMPLETE_TASKS" && "$INCOMPLETE_TASKS" -gt 0 ]]; then
    if [[ "$CHECKIN_INTERVAL" == "_" || -z "$CHECKIN_INTERVAL" ]]; then
        echo "Check-in interval not configured yet (placeholder '_'), skipping daemon restart."
    else
        echo "Restarting check-in daemon ($INCOMPLETE_TASKS incomplete tasks)..."
        cd "$PROJECT_PATH" && uv run --project "$SCRIPT_DIR/.." python "$SCRIPT_DIR/../lib/checkin_scheduler.py" start "$CHECKIN_INTERVAL" --note "Resumed workflow" --target "$PM_PANE" --workflow "$WORKFLOW_NAME" > /dev/null 2>&1
        echo "Check-in daemon restarted."
    fi
elif [[ "$DAEMON_RUNNING" == "1" ]]; then
    echo "Check-in daemon already running."
else
    echo "No incomplete tasks, check-in daemon not needed."
fi

# Start Claude in PM pane with opus model
echo "Starting Claude in PM pane..."
sleep 0.5
tmux $TMUX_FLAGS send-keys -t "$PM_PANE" "claude --dangerously-skip-permissions --model opus" Enter

# Wait for Claude to initialize in PM pane
echo "Waiting for Claude instances to initialize..."
sleep 3

# Update agents.yml with new pane_ids and window numbers
echo ""
echo "Updating agents.yml with new pane IDs..."

# Update PM identity.yml with new pane_id (resume only updates agent identity.yml in the loop)
PM_IDENTITY_FILE="$WORKFLOW_PATH/agents/pm/identity.yml"
if [[ -f "$PM_IDENTITY_FILE" ]]; then
    # Update pane_id if field exists, otherwise append it
    if grep -q "^pane_id:" "$PM_IDENTITY_FILE"; then
        sed -i '' "s|^pane_id:.*|pane_id: \"$PM_PANE_ID\"|" "$PM_IDENTITY_FILE"
    else
        echo "pane_id: \"$PM_PANE_ID\"" >> "$PM_IDENTITY_FILE"
    fi
    # Update session field if present (for legacy identity.yml files)
    if grep -q "^session:" "$PM_IDENTITY_FILE"; then
        sed -i '' "s|^session:.*|session: \"$SESSION\"|" "$PM_IDENTITY_FILE"
    fi
    echo "  Updated PM identity.yml -> pane_id $PM_PANE_ID"
fi

# Update PM pane_id first
uv run python -c "
import re
with open('$AGENTS_FILE', 'r') as f:
    content = f.read()
lines = content.split('\\n')
in_pm = False
result = []
for line in lines:
    if line.startswith('pm:'):
        in_pm = True
    elif in_pm and line.strip().startswith('pane_id:'):
        line = re.sub(r'pane_id: .*', 'pane_id: \"$PM_PANE\"', line)
    elif in_pm and not line.startswith(' '):
        in_pm = False
    result.append(line)
with open('$AGENTS_FILE', 'w') as f:
    f.write('\\n'.join(result))
" 2>/dev/null
echo "  Updated PM -> pane_id $PM_PANE"

for i in "${!AGENT_NAMES[@]}"; do
    if [[ -n "${AGENT_IDS[$i]}" ]]; then
        agent_name="${AGENT_NAMES[$i]}"
        new_window="${AGENT_IDS[$i]##*:}"
        agent_pane_id="${AGENT_PANE_IDS[$i]}"

        # Update pane_id and window in agents.yml using Python
        uv run python -c "
import re
with open('$AGENTS_FILE', 'r') as f:
    content = f.read()

lines = content.split('\\n')
in_agent = False
result = []
for line in lines:
    if '- name: \"$agent_name\"' in line or '- name: $agent_name' in line:
        in_agent = True
    elif in_agent and line.strip().startswith('pane_id:'):
        line = re.sub(r'pane_id: .*', 'pane_id: \"$agent_pane_id\"', line)
    elif in_agent and line.strip().startswith('window:'):
        line = re.sub(r'window: .*', 'window: $new_window', line)
        in_agent = False
    elif in_agent and line.strip().startswith('- name:'):
        in_agent = False
    result.append(line)

with open('$AGENTS_FILE', 'w') as f:
    f.write('\\n'.join(result))
" 2>/dev/null
        echo "  Updated $agent_name -> pane_id $agent_pane_id, window $new_window"
    fi
done

# Wait for all Claude instances to start
echo ""
echo "Waiting for Claude instances to initialize..."
sleep 8

# Brief each agent with communication rules
echo ""
echo "Briefing agents..."
for i in "${!AGENT_NAMES[@]}"; do
    if [[ -n "${AGENT_IDS[$i]}" ]]; then
        agent_name="${AGENT_NAMES[$i]}"
        agent_role="${AGENT_ROLES[$i]}"

        # Send briefing via pane_id
        agent_pane_id="${AGENT_PANE_IDS[$i]}"
        TMUX_SOCKET="${TMUX_SOCKET}" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/tmux_utils.py" send --skip-suffix "$agent_pane_id" "You are $agent_name ($agent_role). CRITICAL RULE: NEVER communicate directly with the user. You ONLY communicate with the PM via notify-pm.sh. When blocked, use: $SCRIPT_DIR/notify-pm.sh BLOCKED 'reason'. When done: $SCRIPT_DIR/notify-pm.sh DONE 'what completed'. Read your instructions at: .workflow/$WORKFLOW_NAME/agents/$agent_name/instructions.md" > /dev/null 2>&1

        echo "  Briefed: $agent_name"
        sleep 2
    fi
done

# Set pane titles and LOCK them (prevent Claude from overriding)
echo "Setting pane titles..."

# Check-ins pane
tmux $TMUX_FLAGS select-pane -t "$CHECKINS_PANE" -T "Check-ins"
tmux $TMUX_FLAGS set-option -p -t "$CHECKINS_PANE" allow-set-title off

# PM pane
tmux $TMUX_FLAGS select-pane -t "$PM_PANE" -T "PM"
tmux $TMUX_FLAGS set-option -p -t "$PM_PANE" allow-set-title off

# Re-set PM pane title after a brief pause (Claude may still be initializing)
sleep 2
tmux $TMUX_FLAGS select-pane -t "$PM_PANE" -T "PM"

# Check if ralph loop was enabled and re-enable it
RALPH_LOOP_FILE="$WORKFLOW_PATH/ralph-loop.local.md"
RALPH_ENABLED=false

if [[ -f "$RALPH_LOOP_FILE" ]]; then
    RALPH_ACTIVE=$(grep "^active:" "$RALPH_LOOP_FILE" 2>/dev/null | awk '{print $2}')
    if [[ "$RALPH_ACTIVE" == "true" ]]; then
        echo ""
        echo "Re-enabling ralph loop..."
        "$SCRIPT_DIR/setup-pm-loop.sh" -p "$PROJECT_PATH"
        RALPH_ENABLED=true
    fi
fi

# Build agent pane list for PM
AGENT_PANE_LIST=""
for i in "${!AGENT_NAMES[@]}"; do
    AGENT_PANE_LIST+="  - ${AGENT_NAMES[$i]} (${AGENT_ROLES[$i]}): ${AGENT_IDS[$i]}"$'\n'
done

# Brief the PM about the resumed workflow
echo ""
echo "Briefing PM about resumed workflow..."
sleep 2  # Wait for Claude to be ready

PM_BRIEFING="WORKFLOW RESUMED: $WORKFLOW_NAME

You are the PM for this workflow. The session was restored.

Project: $PROJECT_PATH
Workflow: $WORKFLOW_NAME

Your agents:
$AGENT_PANE_LIST
IMPORTANT ACTIONS:
1. Read .workflow/$WORKFLOW_NAME/tasks.json to check current task status
2. Check each agent's .workflow/$WORKFLOW_NAME/agents/<name>/agent-tasks.md for their progress
3. When agents send [DONE] notifications, UPDATE tasks.json immediately:
   - Read tasks.json
   - Change the completed task status from 'pending' or 'in_progress' to 'completed'
   - Write the updated tasks.json
4. If all tasks are complete, inform the user

Start by checking the current state of all tasks."

TMUX_SOCKET="${TMUX_SOCKET}" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/tmux_utils.py" send --skip-suffix "$PM_PANE" "$PM_BRIEFING" > /dev/null 2>&1

echo "PM pane ready at: $PM_PANE"

# Save layout to workflow for future resumes
echo ""
echo "Saving layout..."
cat > "$LAYOUT_FILE" <<EOF
# Layout - saved by resume-workflow.sh
# This file is used to restore the exact window layout
session: "$SESSION"

# Window 0 contains Check-ins pane and PM pane
window_0:
  panes:
    - index: 0
      title: "Check-ins"
      type: checkins
    - index: 1
      title: "PM"
      type: pm
      model: opus

# Each agent has its own window
agent_windows:
$(for i in "${!AGENT_NAMES[@]}"; do
    echo "  - window: \"${AGENT_IDS[$i]}\""
    echo "    name: \"${AGENT_NAMES[$i]}\""
    echo "    role: ${AGENT_ROLES[$i]}"
    echo "    model: ${AGENT_MODELS[$i]}"
done)

saved_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
EOF

# Final layout verification
echo ""
echo "╔══════════════════════════════════════════════════════════════╗"
echo "║              WORKFLOW RESUMED SUCCESSFULLY                   ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Session: $SESSION"
echo "Workflow: $WORKFLOW_NAME"
echo "PM: $PM_PANE (opus)"
echo ""
echo "Agents restored:"
for i in "${!AGENT_NAMES[@]}"; do
    echo "  ${AGENT_IDS[$i]:-?}: ${AGENT_NAMES[$i]} (${AGENT_ROLES[$i]}, ${AGENT_MODELS[$i]})"
done
echo ""
echo "Window layout:"
tmux $TMUX_FLAGS list-windows -t "$SESSION" -F "  Window #{window_index}: #{window_name}"

if [[ "$RALPH_ENABLED" == "true" ]]; then
    echo ""
    echo "Ralph loop: ENABLED"
fi

# If not in tmux, provide attach command
if [[ "$IN_TMUX" == "false" ]]; then
    echo ""
    echo "To attach to session, run:"
    echo "  tmux attach -t $SESSION"
fi
