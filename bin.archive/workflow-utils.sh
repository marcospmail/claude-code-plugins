#!/bin/bash
# workflow-utils.sh - Utility functions for workflow management
#
# Source this file in other scripts:
#   source "$(dirname "$0")/workflow-utils.sh"

# Capture the directory where this file lives (when sourced)
# Handle both direct execution and sourcing from different contexts
if [[ -n "${BASH_SOURCE[0]}" ]] && [[ "${BASH_SOURCE[0]}" == *"workflow-utils.sh"* ]]; then
    WORKFLOW_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
else
    # Fallback: assume we're in the yato project and find bin/ directory
    WORKFLOW_UTILS_DIR="$HOME/dev/tools/yato/bin"
fi

# Get the next workflow number (001, 002, etc.)
get_next_workflow_number() {
    local project_path="$1"
    local workflow_dir="$project_path/.workflow"

    if [[ ! -d "$workflow_dir" ]]; then
        echo "001"
        return
    fi

    # Find highest numbered folder
    local max_num=0
    for dir in "$workflow_dir"/[0-9][0-9][0-9]-*/; do
        if [[ -d "$dir" ]]; then
            local num=$(basename "$dir" | cut -d'-' -f1 | sed 's/^0*//')
            if [[ -n "$num" ]] && [[ "$num" -gt "$max_num" ]]; then
                max_num="$num"
            fi
        fi
    done

    printf "%03d" $((max_num + 1))
}

# Generate workflow folder name from user prompt
# Input: "Add user authentication with OAuth"
# Output: "add-user-authentication"
generate_workflow_slug() {
    local prompt="$1"

    # Convert to lowercase, keep only alphanumeric and spaces
    local slug=$(echo "$prompt" | tr '[:upper:]' '[:lower:]' | sed 's/[^a-z0-9 ]//g')

    # Take first 3-5 words
    local words=($slug)
    local max_words=4
    local result=""
    local count=0

    for word in "${words[@]}"; do
        # Skip very short words (a, an, the, etc.)
        if [[ ${#word} -le 2 ]] && [[ "$count" -gt 0 ]]; then
            continue
        fi

        if [[ -n "$result" ]]; then
            result="$result-$word"
        else
            result="$word"
        fi

        ((count++))
        if [[ "$count" -ge "$max_words" ]]; then
            break
        fi
    done

    # Truncate to max 30 characters
    echo "${result:0:30}"
}

# Create a new workflow folder
# Returns the full folder name (e.g., "001-add-user-auth")
create_workflow_folder() {
    local project_path="$1"
    local title="$2"  # User prompt or short description

    local workflow_dir="$project_path/.workflow"
    mkdir -p "$workflow_dir"

    local num=$(get_next_workflow_number "$project_path")
    local slug=$(generate_workflow_slug "$title")
    local folder_name="${num}-${slug}"
    local full_path="$workflow_dir/$folder_name"

    # Create the folder structure
    mkdir -p "$full_path/agents/pm"

    # Create status.yml (initial_request will be added by init-workflow.sh if exists)
    cat > "$full_path/status.yml" <<EOF
# Workflow Status
status: in-progress
title: "$title"
initial_request: ""
folder: "$folder_name"
checkin_interval_minutes: 15
created_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
session: ""
EOF

    echo "$folder_name"
}

# Get current workflow folder name
# Reads from tmux WORKFLOW_NAME env var (preferred) or falls back to .workflow/current file
get_current_workflow() {
    local project_path="$1"

    # First try tmux environment variable (if in tmux)
    if [[ -n "$TMUX" ]]; then
        local tmux_workflow=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
        if [[ -n "$tmux_workflow" ]]; then
            echo "$tmux_workflow"
            return
        fi
    fi

    # Fallback to .workflow/current file (for backward compatibility)
    local current_file="$project_path/.workflow/current"
    if [[ -f "$current_file" ]]; then
        cat "$current_file"
    else
        echo ""
    fi
}

# Get full path to current workflow
get_current_workflow_path() {
    local project_path="$1"
    local current=$(get_current_workflow "$project_path")

    if [[ -n "$current" ]]; then
        echo "$project_path/.workflow/$current"
    else
        echo ""
    fi
}

# Update check-in interval in status.yml
update_checkin_interval() {
    local project_path="$1"
    local interval="$2"

    local workflow_path=$(get_current_workflow_path "$project_path")
    if [[ -z "$workflow_path" ]]; then
        echo "Error: No current workflow" >&2
        return 1
    fi

    local status_file="$workflow_path/status.yml"
    if [[ -f "$status_file" ]]; then
        sed -i '' "s/^checkin_interval_minutes: .*/checkin_interval_minutes: $interval/" "$status_file"
    fi
}

# List all workflows in a project
list_workflows() {
    local project_path="$1"
    local workflow_dir="$project_path/.workflow"

    if [[ ! -d "$workflow_dir" ]]; then
        echo "No workflows found"
        return
    fi

    for dir in "$workflow_dir"/[0-9][0-9][0-9]-*/; do
        if [[ -d "$dir" ]]; then
            local wf_name=$(basename "$dir")
            local wf_status_file="$dir/status.yml"
            local wf_status="unknown"
            local wf_title=""

            if [[ -f "$wf_status_file" ]]; then
                wf_status=$(grep "^status:" "$wf_status_file" | sed 's/status: //')
                wf_title=$(grep "^title:" "$wf_status_file" | sed 's/title: //' | tr -d '"')
            fi

            echo "$wf_name [$wf_status]"
            if [[ -n "$wf_title" ]]; then
                echo "  $wf_title"
            fi
        fi
    done
}

# Create agents.yml file with PM entry
# Usage: create_agents_yml <project_path> <session> [workflow_path]
create_agents_yml() {
    local project_path="$1"
    local session="$2"
    local workflow_path="${3:-}"

    # If workflow_path not provided, try to discover it
    if [[ -z "$workflow_path" ]]; then
        workflow_path=$(get_current_workflow_path "$project_path")
        if [[ -z "$workflow_path" ]]; then
            echo "Error: No current workflow" >&2
            return 1
        fi
    fi

    local agents_file="$workflow_path/agents.yml"

    cat > "$agents_file" <<EOF
# Agent Registry
# This file tracks all agents and their tmux locations

pm:
  name: pm
  role: pm
  session: "$session"
  window: 0
  pane: 1
  model: opus

agents: []
EOF

    echo "Created agents.yml: $agents_file"
}

# Add an agent to agents.yml
add_agent_to_yml() {
    local project_path="$1"
    local agent_name="$2"
    local agent_role="$3"
    local window_number="$4"
    local model="$5"
    local session="$6"

    local workflow_path=$(get_current_workflow_path "$project_path")
    if [[ -z "$workflow_path" ]]; then
        echo "Error: No current workflow" >&2
        return 1
    fi

    local agents_file="$workflow_path/agents.yml"

    if [[ ! -f "$agents_file" ]]; then
        echo "Error: agents.yml not found" >&2
        return 1
    fi

    # Check if agents: [] is empty and replace it with first agent
    if grep -q "^agents: \[\]" "$agents_file"; then
        # First agent - replace empty array
        sed -i '' "s/^agents: \[\]/agents:\\
  - name: $agent_name\\
    role: $agent_role\\
    session: \"$session\"\\
    window: $window_number\\
    model: $model/" "$agents_file"
    else
        # Additional agents - append to array
        cat >> "$agents_file" <<EOF
  - name: $agent_name
    role: $agent_role
    session: "$session"
    window: $window_number
    model: $model
EOF
    fi

    echo "Added $agent_name to agents.yml (window $window_number)"
}

# Save team structure to team.yml and create agent files
# This file is used by /parse-prd-to-tasks to know which agents are available
# Also creates agent folders with identity.yml, instructions.md, agent-tasks.md, etc.
# Usage: save_team_structure <project_path> <agents...>
# Agent format: name:role:model (e.g., "impl:developer:opus" or "qa:qa:sonnet")
save_team_structure() {
    local project_path="$1"
    shift
    local agents=("$@")

    local workflow_path=$(get_current_workflow_path "$project_path")
    if [[ -z "$workflow_path" ]]; then
        echo "Error: No current workflow" >&2
        return 1
    fi

    local team_file="$workflow_path/team.yml"

    # Create team.yml header
    cat > "$team_file" <<EOF
# Team Structure
# This file defines the agents that will be created for this workflow.
# Used by /parse-prd-to-tasks to assign tasks to appropriate agents.
# Created: $(date -u +%Y-%m-%dT%H:%M:%SZ)

agents:
EOF

    # Add each agent to team.yml and create their files
    for agent_spec in "${agents[@]}"; do
        # Parse agent spec: name:role:model
        IFS=':' read -r agent_name agent_role agent_model <<< "$agent_spec"

        # Handle simple format (just role)
        if [[ -z "$agent_role" ]]; then
            agent_role="$agent_name"
            agent_name="$agent_role"
            agent_model="sonnet"
        fi

        # Handle name:role format (no model)
        if [[ -z "$agent_model" ]]; then
            agent_model="sonnet"
        fi

        # Add to team.yml
        cat >> "$team_file" <<EOF
  - name: $agent_name
    role: $agent_role
    model: $agent_model
EOF

        # Create agent files (identity.yml, instructions.md, agent-tasks.md, etc.)
        "$WORKFLOW_UTILS_DIR/init-agent-files.sh" "$project_path" "$agent_name" "$agent_role" "$agent_model"
    done

    echo "Saved team structure to: $team_file"
}
