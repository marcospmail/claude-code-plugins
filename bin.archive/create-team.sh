#!/bin/bash
# create-team.sh - Create specified agents in the CURRENT session
# This script auto-detects the session to prevent PM errors
#
# Usage: ./create-team.sh <project_path> <agent-role> [agent-role...]
#
# Agent roles (specify which ones you need):
#   - developer, qa, code-reviewer
#   - backend-developer, frontend-developer, designer, devops, etc.
#
# Agent format: role OR name:role:model
#   - Simple: developer, qa, code-reviewer
#   - Custom: mydev:developer:opus, qa-tester:qa:sonnet
#
# Examples:
#   ./create-team.sh /path/to/project qa                    # Single QA agent (default model)
#   ./create-team.sh /path/to/project developer             # Single developer (default model)
#   ./create-team.sh /path/to/project developer qa code-reviewer  # Full team
#   ./create-team.sh /path/to/project backend-developer frontend-developer  # Specialized team
#   ./create-team.sh /path/to/project impl:developer:opus val:qa:opus  # Custom names/models

set -e

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

# Support isolated tmux socket (used by e2e tests)
TMUX_FLAGS="${TMUX_SOCKET:+-L $TMUX_SOCKET}"

# Source workflow utilities
source "$SCRIPT_DIR/workflow-utils.sh"

PROJECT_PATH="${1:-$(pwd)}"
shift 2>/dev/null || true  # Remove first arg, rest are agent roles
AGENTS=("$@")

# Validate that at least one agent role is provided
if [[ ${#AGENTS[@]} -eq 0 ]]; then
    echo "ERROR: No agent roles specified."
    echo ""
    echo "Usage: $0 <project_path> <agent-role> [agent-role...]"
    echo ""
    echo "Examples:"
    echo "  $0 /path/to/project qa                          # Single QA"
    echo "  $0 /path/to/project developer                   # Single developer"
    echo "  $0 /path/to/project developer qa code-reviewer  # Full team"
    exit 1
fi

# Expand project path
PROJECT_PATH=$(eval echo "$PROJECT_PATH")

# AUTO-DETECT current session
# Try tmux display-message first (works when running inside tmux)
SESSION=$(tmux $TMUX_FLAGS display-message -p '#S' 2>/dev/null || echo "")
if [[ -z "$SESSION" ]]; then
    # Fallback: find the session whose pane has PROJECT_PATH as current directory
    SESSION=$(tmux $TMUX_FLAGS list-panes -a -F "#{session_name} #{pane_current_path}" 2>/dev/null | grep "$PROJECT_PATH" | head -1 | awk '{print $1}')
fi
if [[ -z "$SESSION" ]]; then
    echo "ERROR: Could not detect tmux session. Are you running inside tmux?"
    exit 1
fi

# Check for active workflow
CURRENT_WORKFLOW=$(get_current_workflow "$PROJECT_PATH")
WORKFLOW_PATH=$(get_current_workflow_path "$PROJECT_PATH")

if [[ -z "$CURRENT_WORKFLOW" ]]; then
    echo "WARNING: No active workflow found in $PROJECT_PATH"
    echo "Creating team without workflow context."
    echo "To create a workflow first, run:"
    echo "  $SCRIPT_DIR/init-workflow.sh $PROJECT_PATH \"Your task title\""
    echo ""
fi

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║           CREATING TEAM IN SESSION: $SESSION"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Project path: $PROJECT_PATH"
echo "Session: $SESSION"
[[ -n "$CURRENT_WORKFLOW" ]] && echo "Workflow: $CURRENT_WORKFLOW"
echo ""

# PM is always at 0.1
PM_WINDOW="$SESSION:0.1"

# Track created agents
CREATED_AGENTS=()

# Function to get default model for agent role
get_default_model() {
    local role=$1
    case "$role" in
        code-reviewer)
            echo "opus"
            ;;
        developer|qa|backend-developer|frontend-developer|designer|devops)
            echo "sonnet"
            ;;
        *)
            echo "sonnet"  # Default to sonnet
            ;;
    esac
}

# Count occurrences of each role for smart naming (bash 3.2 compatible)
count_role() {
    local role="$1"
    local count=0
    for r in "${AGENTS[@]}"; do
        [[ "$r" == "$role" ]] && ((count++))
    done
    echo "$count"
}

# Track role instance numbers using simple string matching
ROLE_INSTANCES=""

# Function to create an agent
create_agent() {
    local role=$1
    local name=$2
    local model=$3
    local window_num=$4

    echo "Creating $role ($name) with model $model in window $window_num..."

    # Create agent in new window (not pane)
    local output=$("$SCRIPT_DIR/create-agent.sh" "$SESSION" "$role" \
        -n "$name" \
        -m "$model" \
        -p "$PROJECT_PATH" \
        --pm-window "$PM_WINDOW" 2>&1)

    local exit_code=$?
    echo "$output" | grep -E "(Agent ID|Error|Created window|Starting Claude)"

    if [[ $exit_code -eq 0 ]]; then
        CREATED_AGENTS+=("$name:$role:$window_num")
        # Note: Agent is already added to agents.yml by create-agent.sh
    else
        echo "WARNING: Failed to create $role"
    fi
    echo ""
}

# Create agents based on provided roles
echo "=== Creating Team Agents ==="
WINDOW_NUM=1

for agent_spec in "${AGENTS[@]}"; do
    # Parse agent spec: can be "role" or "name:role:model"
    # Count colons to determine format
    colon_count=$(echo "$agent_spec" | tr -cd ':' | wc -c | tr -d ' ')

    if [[ $colon_count -eq 2 ]]; then
        # Format: name:role:model (e.g., "qa-impl:developer:opus")
        IFS=':' read -r agent_name agent_role model <<< "$agent_spec"

        # Validate parsing worked correctly
        if [[ -z "$agent_name" || -z "$agent_role" || -z "$model" ]]; then
            echo "ERROR: Failed to parse agent spec '$agent_spec'. Expected format: name:role:model"
            continue
        fi

        # Validate model is valid
        if [[ "$model" != "opus" && "$model" != "sonnet" && "$model" != "haiku" ]]; then
            echo "WARNING: Invalid model '$model' for $agent_name, using default for role '$agent_role'"
            model=$(get_default_model "$agent_role")
        fi

        echo "Parsed: name=$agent_name, role=$agent_role, model=$model"
    elif [[ $colon_count -eq 1 ]]; then
        # Format: name:role (e.g., "my-dev:developer")
        IFS=':' read -r agent_name agent_role <<< "$agent_spec"

        # Validate parsing worked
        if [[ -z "$agent_name" || -z "$agent_role" ]]; then
            echo "ERROR: Failed to parse agent spec '$agent_spec'. Expected format: name:role"
            continue
        fi

        model=$(get_default_model "$agent_role")
        echo "Parsed: name=$agent_name, role=$agent_role, model=$model (default)"
    else
        # Format: role (simple format)
        agent_role="$agent_spec"
        model=$(get_default_model "$agent_role")

        # Smart naming: only add number if multiple of same role
        role_count=$(count_role "$agent_role")
        if [[ $role_count -gt 1 ]]; then
            # Multiple of this role - use numbered names
            # Count how many of this role we've already created (bash 3.2 compatible)
            instance_num=0
            if [[ -n "$ROLE_INSTANCES" ]]; then
                for r in $ROLE_INSTANCES; do
                    [[ "$r" == "$agent_role" ]] && instance_num=$((instance_num + 1))
                done
            fi
            instance_num=$((instance_num + 1))
            agent_name="${agent_role}-${instance_num}"
            ROLE_INSTANCES="$ROLE_INSTANCES$agent_role "
        else
            # Single instance of this role - use role name directly
            agent_name="$agent_role"
        fi
    fi

    create_agent "$agent_role" "$agent_name" "$model" "$WINDOW_NUM"
    ((WINDOW_NUM++))
done

echo "╔══════════════════════════════════════════════════════════════╗"
echo "║                    TEAM CREATION COMPLETE                    ║"
echo "╚══════════════════════════════════════════════════════════════╝"
echo ""
echo "Session: $SESSION"
echo "Agents created: ${#CREATED_AGENTS[@]}"
for agent in "${CREATED_AGENTS[@]}"; do
    IFS=':' read -r name role window <<< "$agent"
    echo "  - $name ($role) - window $window"
done
echo ""
echo "Layout verification:"
tmux $TMUX_FLAGS list-windows -t "$SESSION" -F "  Window #{window_index}: #{window_name}"
echo ""
echo "All agents are running Claude and ready to receive tasks."
echo ""
echo "Agent registry: .workflow/$(get_current_workflow \"$PROJECT_PATH\")/agents.yml"
