#!/bin/bash
# create-agent.sh - Create and register a new Claude agent
#
# This script:
# 1. Creates a new tmux window in the specified session
# 2. Registers the agent in the registry
# 3. Starts Claude
# 4. Briefs the agent with role-specific instructions
#
# Usage: ./create-agent.sh <session> <role> [options]
#
# Arguments:
#   session     The tmux session name
#   role        Agent role (any name: pm, developer, qa, backend-dev, frontend-dev, etc.)
#
# Options:
#   -p, --path      Project path (working directory for the agent)
#   -n, --name      Window name (defaults to Claude-<Role>)
#   --no-start      Don't start Claude automatically
#   --no-brief      Don't send briefing message
#   -h, --help      Show this help message
#
# Examples:
#   ./create-agent.sh myproject developer -p ~/projects/myapp
#   ./create-agent.sh myproject pm -p ~/projects/myapp
#   ./create-agent.sh myproject qa

set -e

# Support isolated tmux socket (used by e2e tests)
TMUX_FLAGS="${TMUX_SOCKET:+-L $TMUX_SOCKET}"

# Get script directory for portable paths
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
LIB_DIR="$PROJECT_ROOT/lib"
TEMPLATES_DIR="$PROJECT_ROOT/templates"

# Source workflow utilities
source "$SCRIPT_DIR/workflow-utils.sh"

# Default values
SESSION=""
ROLE=""
PROJECT_PATH=""
WINDOW_NAME=""
MODEL=""
START_CLAUDE=true
SEND_BRIEF=true

# Valid roles - removed validation to allow any custom role names
# VALID_ROLES="orchestrator pm developer qa devops reviewer researcher writer"

# Help message
show_help() {
    cat << EOF
Usage: $(basename "$0") <session> <role> [options]

Create and register a new Claude agent in a tmux session.

Arguments:
  session     The tmux session name
  role        Agent role (any name: developer, qa, backend-dev, frontend-dev, etc.)

Options:
  -p, --path      Project path (working directory)
  -n, --name      Window name (default: <Role>)
  -m, --model     Claude model to use (opus, sonnet, haiku)
  --no-start      Don't start Claude automatically
  --no-brief      Don't send briefing message
  -h, --help      Show this help

Examples:
  $(basename "$0") myproject developer -p ~/projects/myapp
  $(basename "$0") myproject backend-dev -p ~/projects/myapp
  $(basename "$0") myproject code-reviewer -m opus -p ~/projects/myapp
EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -h|--help)
            show_help
            exit 0
            ;;
        -p|--path)
            PROJECT_PATH="$2"
            shift 2
            ;;
        -n|--name)
            WINDOW_NAME="$2"
            shift 2
            ;;
        -m|--model)
            MODEL="$2"
            shift 2
            ;;
        --no-start)
            START_CLAUDE=false
            shift
            ;;
        --no-brief)
            SEND_BRIEF=false
            shift
            ;;
        -*)
            echo "Unknown option: $1"
            show_help
            exit 1
            ;;
        *)
            if [[ -z "$SESSION" ]]; then
                SESSION="$1"
            elif [[ -z "$ROLE" ]]; then
                ROLE="$1"
            else
                echo "Unexpected argument: $1"
                show_help
                exit 1
            fi
            shift
            ;;
    esac
done

# Validate required arguments
if [[ -z "$SESSION" ]] || [[ -z "$ROLE" ]]; then
    echo "Error: session and role are required"
    show_help
    exit 1
fi

# Normalize role to lowercase (but don't validate - allow any role name)
ROLE=$(echo "$ROLE" | tr '[:upper:]' '[:lower:]')

# Set default window name - just the role capitalized
if [[ -z "$WINDOW_NAME" ]]; then
    WINDOW_NAME=$(echo "$ROLE" | sed 's/.*/\u&/')
fi

# Create capitalized role for display in instructions
ROLE_CAPITALIZED=$(echo "$ROLE" | sed 's/\b\(.\)/\u\1/g')

# Check session exists
if ! tmux $TMUX_FLAGS has-session -t "$SESSION" 2>/dev/null; then
    echo "Error: Session '$SESSION' does not exist"
    echo "Create it with: tmux new-session -d -s $SESSION"
    exit 1
fi

# Expand project path if provided
if [[ -n "$PROJECT_PATH" ]]; then
    PROJECT_PATH=$(eval echo "$PROJECT_PATH")
    if [[ ! -d "$PROJECT_PATH" ]]; then
        echo "Warning: Path '$PROJECT_PATH' does not exist"
    fi
fi

# Create agent window
echo "Creating window '$WINDOW_NAME' in session '$SESSION'..."

if [[ -n "$PROJECT_PATH" ]]; then
    WINDOW_OUTPUT=$(tmux $TMUX_FLAGS new-window -d -t "$SESSION" -n "$WINDOW_NAME" -c "$PROJECT_PATH" -P -F "#{window_index}:#{pane_id}")
else
    WINDOW_OUTPUT=$(tmux $TMUX_FLAGS new-window -d -t "$SESSION" -n "$WINDOW_NAME" -P -F "#{window_index}:#{pane_id}")
fi

if [[ -z "$WINDOW_OUTPUT" ]]; then
    echo "Error: Failed to create window"
    exit 1
fi

WINDOW_INDEX="${WINDOW_OUTPUT%%:*}"
PANE_ID="${WINDOW_OUTPUT#*:}"
AGENT_ID="$SESSION:$WINDOW_INDEX"
echo "Created window: $AGENT_ID (pane_id: $PANE_ID)"

# Register the agent in workflow agents.yml (uses workflow-utils.sh which was sourced earlier)
echo "Registering agent in workflow..."
if [[ -n "$PROJECT_PATH" ]]; then
    # Use lowercase window name as agent name (e.g., "developer", "qa-1")
    AGENT_NAME=$(echo "$WINDOW_NAME" | tr '[:upper:]' '[:lower:]')
    add_agent_to_yml "$PROJECT_PATH" "$AGENT_NAME" "$ROLE" "$WINDOW_INDEX" "${MODEL:-sonnet}" "$SESSION" "$PANE_ID"
fi

# Create or update agent identity file
if [[ -n "$PROJECT_PATH" ]]; then
    # Get current workflow path (pass session name to query its env)
    WORKFLOW_PATH=$(get_current_workflow_path "$PROJECT_PATH" "$SESSION")
    if [[ -n "$WORKFLOW_PATH" ]]; then
        # Use agent name (lowercase window name) to find agent folder
        AGENT_NAME_LOWER=$(echo "$WINDOW_NAME" | tr '[:upper:]' '[:lower:]')
        AGENT_DIR="${WORKFLOW_PATH}/agents/${AGENT_NAME_LOWER}"
    else
        echo "Warning: No active workflow found. Creating agents directory."
        # Create a default agents directory under .workflow if no workflow exists
        mkdir -p "${PROJECT_PATH}/.workflow"
        AGENT_DIR="${PROJECT_PATH}/.workflow/agents/${ROLE}"
    fi

    # Check if agent files were pre-created by init-agent-files.sh
    IDENTITY_FILE="$AGENT_DIR/identity.yml"
    if [[ -f "$IDENTITY_FILE" ]]; then
        # Files exist - just update pane_id and window in identity.yml
        echo "Updating existing agent files with pane_id and window info..."
        sed -i '' "s/^pane_id:.*/pane_id: \"${PANE_ID}\"/" "$IDENTITY_FILE"
        sed -i '' "s/^window:.*/window: ${WINDOW_INDEX}/" "$IDENTITY_FILE"
        echo "Updated identity file: $IDENTITY_FILE"
    else
        # Files don't exist - create everything (backward compatibility)
        mkdir -p "$AGENT_DIR"

        # Determine if agent can modify code and purpose from agents/*.yml
        AGENT_YML_INFO=$(uv run --project "$SCRIPT_DIR/.." python -c "
import yaml, sys, pathlib
agents_dir = pathlib.Path('$SCRIPT_DIR/../agents')
for f in agents_dir.glob('*.yml'):
    with open(f) as fh:
        data = yaml.safe_load(fh)
    if data and data.get('name') == '$ROLE':
        can_modify = data.get('can_modify_code', True)
        # Normalize: true/false/test-only -> true/false
        if isinstance(can_modify, str) and can_modify not in ('true', 'false'):
            can_modify = False
        print(f'{str(can_modify).lower()}|{data.get(\"description\", \"\")}')
        sys.exit(0)
# Fallback for unknown roles
if 'developer' in '$ROLE' or 'dev' in '$ROLE':
    print('true|Development and implementation')
else:
    print('false|Support and analysis')
" 2>/dev/null) || AGENT_YML_INFO="true|Implementation and development"
        CAN_MODIFY_CODE="${AGENT_YML_INFO%%|*}"
        AGENT_PURPOSE="${AGENT_YML_INFO#*|}"

        # Create identity.yml (pane_id-based format)
        cat > "$AGENT_DIR/identity.yml" <<EOF
name: ${WINDOW_NAME}
role: ${ROLE}
model: ${MODEL:-sonnet}
pane_id: "${PANE_ID}"
window: ${WINDOW_INDEX}
workflow: ${WORKFLOW_NAME:-default}
can_modify_code: ${CAN_MODIFY_CODE}
EOF

        echo "Created identity file: $AGENT_DIR/identity.yml"

        # Create instructions.md with role-based content (positive guidance only, no NEVER rules)
    cat > "$AGENT_DIR/instructions.md" <<EOF
# Instructions for ${ROLE_CAPITALIZED}

## Role
${AGENT_PURPOSE}

## Description
$(if [[ "$CAN_MODIFY_CODE" == "true" ]]; then
    echo "You are responsible for writing and modifying code."
else
    echo "You review, test, or analyze code but do NOT modify it directly."
    echo "Any changes must be requested from developers."
fi)

## Responsibilities
$(uv run --project "$SCRIPT_DIR/.." python -c "
import yaml, pathlib
agents_dir = pathlib.Path('$SCRIPT_DIR/../agents')
for f in agents_dir.glob('*.yml'):
    with open(f) as fh:
        data = yaml.safe_load(fh)
    if data and data.get('name') == '$ROLE':
        instructions = data.get('instructions', '').strip()
        if instructions:
            print(instructions)
        else:
            print('- Follow instructions from PM')
            print('- Update agent-tasks.md as you work')
            print('- Notify PM when blocked or done')
        exit(0)
print('- Follow instructions from PM')
print('- Update agent-tasks.md as you work')
print('- Notify PM when blocked or done')
" 2>/dev/null || {
    echo "- Follow instructions from PM"
    echo "- Update agent-tasks.md as you work"
    echo "- Notify PM when blocked or done"
})

## Communication
- Notify PM using: notify-pm.sh "[STATUS] message"
- notify-pm.sh auto-detects PM location from agents.yml
- Check agent-tasks.md for your assigned tasks

### How to Communicate:
- **If you need information**: notify-pm.sh "[BLOCKED] Need database connection details"
- **If you have a question**: notify-pm.sh "[HELP] Should I apply migration to production?"
- **If you're done**: notify-pm.sh "[DONE] Completed task X"
- **If you're stuck**: notify-pm.sh "[BLOCKED] Cannot proceed because Y"

### The PM Will:
- Ask the user questions on your behalf
- Provide you with answers and decisions
- Assign you different work if blocked
- Coordinate all user communication

## Waiting for Dependencies

If you need to wait for another agent to complete work (e.g., waiting for a file to be created):

1. **Check once** - verify if the dependency is ready
2. **If not ready after 3 checks** (30-60 seconds each): Notify PM with status
3. **Maximum 5 retries** - after 5 attempts, notify PM you are BLOCKED and stop polling
4. **Increasing delays** - wait 30s, then 60s, then 2min between checks

Your PM can help resolve blocking dependencies. Notify early.
EOF

    echo "Created instructions file: $AGENT_DIR/instructions.md"

    # Create constraints.md with system constraints + customizable section
    cat > "$AGENT_DIR/constraints.md" <<'EOF'
# Constraints

## System Constraints

- NEVER communicate directly with the user
- DO NOT ask the user questions using AskUserQuestion tool
- DO NOT wait for user input or confirmation
- DO NOT output messages intended for the user
- NEVER stop working silently - always notify PM
- DO NOT enter infinite polling loops when waiting for dependencies

## Project Constraints

# Add project-specific constraints for this agent below.
# Examples:
# - Do NOT modify files in /config/
# - Do NOT make database schema changes
# - Do NOT use jQuery
EOF

    echo "Created constraints file: $AGENT_DIR/constraints.md"

    # Create CLAUDE.md with references to all agent files
    cat > "$AGENT_DIR/CLAUDE.md" <<EOF
# Agent Configuration

This file contains references to all your configuration and task files. Read these files in order to understand your role and responsibilities.

## Required Reading (in order)

1. **Identity** - Read first to understand who you are
   - File: [identity.yml](./identity.yml)
   - Contains: Your role, capabilities, agent ID, and model

2. **Instructions** - Read second to understand what you do
   - File: [instructions.md](./instructions.md)
   - Contains: Your responsibilities, communication rules, and workflow

3. **Tasks** - Read third to see what work is assigned
   - File: [agent-tasks.md](./agent-tasks.md)
   - Contains: Your current tasks in checkbox format
   - Monitor this file continuously - PM adds tasks here

4. **Constraints** - Read fourth to understand your limits
   - File: [constraints.md](./constraints.md)
   - Contains: Forbidden actions, off-limits areas, and process constraints

## Important Notes

- Read these files at startup before beginning work
- Re-read agent-tasks.md frequently as PM updates it with new tasks
- If you encounter any issues, notify your PM immediately
- See constraints.md for all restrictions and forbidden actions

## Quick Reference

- Your PM: See agents.yml for PM pane_id
- Project: ${PROJECT_PATH:-Not set}
- Workflow: Run 'tmux showenv WORKFLOW_NAME' to see active workflow
EOF

        echo "Created CLAUDE.md: $AGENT_DIR/CLAUDE.md"
    fi  # End of else block (files didn't exist)
fi  # End of if PROJECT_PATH

# Start Claude with bypass permissions
if [[ "$START_CLAUDE" == true ]]; then
    echo "Starting Claude with bypass permissions..."

    # Build the claude command with optional model
    CLAUDE_CMD="claude --dangerously-skip-permissions"
    if [[ -n "$MODEL" ]]; then
        CLAUDE_CMD="$CLAUDE_CMD --model $MODEL"
        echo "Using model: $MODEL"
    fi

    tmux $TMUX_FLAGS send-keys -t "$AGENT_ID" "$CLAUDE_CMD" Enter
    sleep 5  # Wait for Claude to start

    # Re-set pane title after Claude starts (Claude overrides it)
    # Do it multiple times to ensure it sticks
    if [[ "$USE_PANE" == true ]]; then
        tmux $TMUX_FLAGS select-pane -t "$AGENT_ID" -T "$WINDOW_NAME"
        sleep 2
        tmux $TMUX_FLAGS select-pane -t "$AGENT_ID" -T "$WINDOW_NAME"
    fi
fi

# Send briefing
if [[ "$SEND_BRIEF" == true ]] && [[ "$START_CLAUDE" == true ]]; then
    echo "Sending briefing..."

    # All agents use engineer briefing (PM is created via deploy-pm with its own briefing)
    TEMPLATE="$TEMPLATES_DIR/engineer-briefing.md"

    if [[ -f "$TEMPLATE" ]]; then
        # Read and customize the template
        BRIEFING=$(cat "$TEMPLATE" | \
            sed "s|{PROJECT_PATH}|${PROJECT_PATH:-$(pwd)}|g" | \
            sed "s|{SESSION_NAME}|$SESSION|g" | \
            sed "s|{ORCHESTRATOR_PATH}|$PROJECT_ROOT|g" | \
            )

        # Read can_modify_code from identity.yml if it exists
        # Use AGENT_DIR set earlier, with fallback for safety
        IDENTITY_FILE="${AGENT_DIR:-${PROJECT_PATH}/.workflow/agents/${ROLE}}/identity.yml"
        if [[ -f "$IDENTITY_FILE" ]]; then
            CAN_MODIFY=$(grep "can_modify_code:" "$IDENTITY_FILE" | awk '{print $2}')
        else
            CAN_MODIFY="true"
        fi

        # Create a summary briefing for initial message
        CODE_RESTRICTION=""
        if [[ "$CAN_MODIFY" == "false" ]]; then
            CODE_RESTRICTION="

CRITICAL - CODE MODIFICATION RESTRICTION:
- You are a $ROLE - you CANNOT modify code directly
- Your role: review, test, analyze, and provide feedback
- When you find issues: create detailed reports and ask DEVELOPERS to fix them
- NEVER use Edit, Write, or any code modification tools
- Focus on quality assurance, testing, and recommendations"
        fi

        # Get workflow-relative path for display
        WORKFLOW_NAME=$(get_current_workflow "$PROJECT_PATH" "$SESSION")
        if [[ -n "$WORKFLOW_NAME" ]]; then
            WORKFLOW_REL=".workflow/$WORKFLOW_NAME"
        else
            WORKFLOW_REL=".workflow"
        fi

        # Use agent name (lowercase window name) for folder paths - must match init-agent-files.sh
        AGENT_NAME_FOR_PATH=$(echo "$WINDOW_NAME" | tr '[:upper:]' '[:lower:]')

        SUMMARY_BRIEF="You are now a $ROLE for this project.

Your window: $SESSION:$WINDOW_INDEX
Project path: ${PROJECT_PATH:-$(pwd)}
Workflow: ${WORKFLOW_NAME:-default}
Identity file: $WORKFLOW_REL/agents/$AGENT_NAME_FOR_PATH/identity.yml$CODE_RESTRICTION

⚠️ CRITICAL - NEVER COMMUNICATE WITH USER ⚠️
- You ONLY communicate with your PM via notify-pm.sh
- NEVER use AskUserQuestion tool - notify PM instead
- NEVER wait for user input - notify PM if blocked
- If you need information: notify-pm.sh \"[HELP] your question\"
- If you're blocked: notify-pm.sh \"[BLOCKED] why you're blocked\"
- PM will handle ALL user communication on your behalf

CRITICAL - TASK TRACKING:
- Your tasks are in: $WORKFLOW_REL/agents/$AGENT_NAME_FOR_PATH/agent-tasks.md
- FORMAT: Only two sections - '## Tasks' (checkboxes) and '## References' (links/docs)
- MONITOR this file continuously - PM will add tasks to the Tasks section
- CHECK OFF items as you complete them (change [ ] to [x])
- The LAST checkbox is ALWAYS 'Notify PM when done' - you MUST complete this

TO NOTIFY PM - use notify-pm.sh:
  $PROJECT_ROOT/bin/notify-pm.sh \"[DONE] from $AGENT_NAME_FOR_PATH: <your message>\"

Message types: DONE, BLOCKED, HELP, STATUS, PROGRESS
notify-pm.sh auto-detects PM location - just run it

Wait for PM to assign your first tasks via agent-tasks.md."

        # Send the summary brief
        TMUX_SOCKET="${TMUX_SOCKET}" uv run --project "$PROJECT_ROOT" python "$PROJECT_ROOT/lib/tmux_utils.py" send --skip-suffix "$AGENT_ID" "$SUMMARY_BRIEF"
    else
        echo "Warning: Template not found: $TEMPLATE"
    fi
fi

# Final pane title set - after briefing when Claude is fully running
if [[ "$USE_PANE" == true ]]; then
    sleep 1
    tmux $TMUX_FLAGS select-pane -t "$AGENT_ID" -T "$WINDOW_NAME"
fi

echo ""
echo "Agent created successfully!"
echo "  Agent ID: $AGENT_ID"
echo "  Role: $ROLE"
echo "  Window: $WINDOW_NAME"
[[ -n "$PROJECT_PATH" ]] && echo "  Path: $PROJECT_PATH"
echo ""
echo "To interact with this agent:"
echo "  tmux select-window -t $AGENT_ID"
echo "  uv run --project $PROJECT_ROOT python $PROJECT_ROOT/lib/tmux_utils.py send $AGENT_ID \"Your message\""
