#!/bin/bash
# workflow-utils.sh - Utility functions for workflow management
#
# Source this file in other scripts:
#   source "$(dirname "$0")/workflow-utils.sh"

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

# Set current workflow
# Sets tmux WORKFLOW_NAME env var (if in tmux)
# No longer writes to .workflow/current file
set_current_workflow() {
    local project_path="$1"
    local folder_name="$2"

    local workflow_dir="$project_path/.workflow"
    local full_path="$workflow_dir/$folder_name"

    if [[ -d "$full_path" ]]; then
        # Set tmux environment variable (if in tmux)
        if [[ -n "$TMUX" ]]; then
            tmux setenv WORKFLOW_NAME "$folder_name"
        fi
        return 0
    else
        echo "Error: Workflow folder not found: $full_path" >&2
        return 1
    fi
}

# Update workflow status
update_workflow_status() {
    local project_path="$1"
    local new_status="$2"  # in-progress, completed, paused

    local workflow_path=$(get_current_workflow_path "$project_path")
    if [[ -z "$workflow_path" ]]; then
        echo "Error: No current workflow" >&2
        return 1
    fi

    local status_file="$workflow_path/status.yml"
    if [[ -f "$status_file" ]]; then
        sed -i '' "s/^status: .*/status: $new_status/" "$status_file"
    fi
}

# Update session in status.yml
update_workflow_session() {
    local project_path="$1"
    local session="$2"

    local workflow_path=$(get_current_workflow_path "$project_path")
    if [[ -z "$workflow_path" ]]; then
        echo "Error: No current workflow" >&2
        return 1
    fi

    local status_file="$workflow_path/status.yml"
    if [[ -f "$status_file" ]]; then
        sed -i '' "s/^session: .*/session: \"$session\"/" "$status_file"
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

# Get workflow info as JSON (for resume)
get_workflow_info() {
    local project_path="$1"
    local workflow_name="$2"

    local workflow_path="$project_path/.workflow/$workflow_name"
    local status_file="$workflow_path/status.yml"

    if [[ ! -f "$status_file" ]]; then
        echo "{}"
        return 1
    fi

    # Parse status.yml
    local wf_status=$(grep "^status:" "$status_file" | sed 's/status: //')
    local wf_title=$(grep "^title:" "$status_file" | sed 's/title: //' | tr -d '"')
    local wf_session=$(grep "^session:" "$status_file" | sed 's/session: //' | tr -d '"')
    local wf_interval=$(grep "^checkin_interval_minutes:" "$status_file" | sed 's/checkin_interval_minutes: //')

    # List agents
    local wf_agents=""
    for agent_dir in "$workflow_path/agents"/*/; do
        if [[ -d "$agent_dir" ]] && [[ -f "$agent_dir/identity.yml" ]]; then
            local agent_name=$(basename "$agent_dir")
            if [[ -n "$wf_agents" ]]; then
                wf_agents="$wf_agents,$agent_name"
            else
                wf_agents="$agent_name"
            fi
        fi
    done

    cat <<EOF
{
  "name": "$workflow_name",
  "status": "$wf_status",
  "title": "$wf_title",
  "session": "$wf_session",
  "checkin_interval_minutes": $wf_interval,
  "agents": ["${wf_agents//,/\",\"}"],
  "path": "$workflow_path"
}
EOF
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

# Get window number for an agent by name
get_agent_window() {
    local project_path="$1"
    local agent_name="$2"

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

    # Find the agent entry and get the window number
    # This assumes agents are in YAML format with consistent indentation
    local window=$(awk "/^  - name: $agent_name$/,/^  - name:/ { if (/^    window:/) print \$2; exit }" "$agents_file")

    if [[ -z "$window" ]]; then
        # Try PM entry
        window=$(awk "/^pm:$/,/^agents:/ { if (/^  window:/) print \$2; exit }" "$agents_file")
    fi

    echo "$window"
}

# List all agents from agents.yml
list_agents_from_yml() {
    local project_path="$1"

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

    echo "PM:"
    grep -A 5 "^pm:" "$agents_file" | grep -E "  (name|role|window|pane):" | sed 's/^  /  /'

    echo ""
    echo "Agents:"
    grep -A 4 "^  - name:" "$agents_file" | grep -E "  - name:|    (role|window|model):" | sed 's/^    /  /'
}
