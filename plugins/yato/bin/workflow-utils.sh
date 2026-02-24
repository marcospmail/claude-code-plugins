#!/bin/bash
# workflow-utils.sh - Utility functions for workflow management
#
# Source this file in other scripts:
#   source "$(dirname "$0")/workflow-utils.sh"

# Capture the directory where this file lives (when sourced)
# Must work in both bash and zsh since Claude's bash tool uses zsh
if [[ -n "${BASH_SOURCE[0]:-}" ]] && [[ "${BASH_SOURCE[0]}" == *"workflow-utils.sh"* ]]; then
    # bash: BASH_SOURCE tracks sourced file paths
    WORKFLOW_UTILS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
elif [[ -n "${CLAUDE_PLUGIN_ROOT:-}" ]]; then
    # zsh fallback: CLAUDE_PLUGIN_ROOT is always set by Claude Code plugin system
    WORKFLOW_UTILS_DIR="${CLAUDE_PLUGIN_ROOT}/bin"
elif [[ -n "${0}" ]] && [[ -f "${0}" ]] && [[ "${0}" == *"workflow-utils.sh"* ]]; then
    # zsh: $0 contains the sourced file when using 'source' command
    WORKFLOW_UTILS_DIR="$(cd "$(dirname "$0")" && pwd)"
else
    # Last resort: search common locations
    for _candidate in "$(dirname "$0")" "$(dirname "$0")/.." "$(pwd)"; do
        if [[ -f "$_candidate/bin/workflow-utils.sh" ]]; then
            WORKFLOW_UTILS_DIR="$_candidate/bin"
            break
        elif [[ -f "$_candidate/workflow-utils.sh" ]]; then
            WORKFLOW_UTILS_DIR="$_candidate"
            break
        fi
    done
    unset _candidate
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

    # Create the folder structure (agents/pm/ is created later by agent_manager.py init-files)
    mkdir -p "$full_path"

    # Create status.yml (initial_request will be added by init-workflow.sh if exists)
    # Note: checkin_interval_minutes uses "_" as placeholder until user selects interval
    # Note: folder uses absolute path for clarity
    cat > "$full_path/status.yml" <<EOF
# Workflow Status
status: in-progress
title: "$title"
initial_request: ""
folder: "$full_path"
checkin_interval_minutes: _
created_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
session: _
agent_message_suffix: ""
checkin_message_suffix: ""
agent_to_pm_message_suffix: ""
EOF

    echo "$folder_name"
}

# Get current workflow folder name from tmux WORKFLOW_NAME env var
# Args:
#   $1: project_path (required)
#   $2: session_name (optional) - if provided, queries that session's env
# Returns workflow folder name or empty string
get_current_workflow() {
    local project_path="$1"
    local session_name="${2:-}"

    # Check _YATO_WORKFLOW_NAME override (set by save_team_structure to ensure
    # init-agent-files.sh targets the correct workflow, not the tmux session's)
    if [[ -n "${_YATO_WORKFLOW_NAME:-}" ]]; then
        echo "$_YATO_WORKFLOW_NAME"
        return
    fi

    # If session name provided, query that session directly
    # Note: TMUX_FLAGS is set by calling scripts (create-team.sh, create-agent.sh, etc.)
    local _tmux_flags="${TMUX_SOCKET:+-L $TMUX_SOCKET}"
    if [[ -n "$session_name" ]]; then
        local tmux_workflow=$(tmux $_tmux_flags showenv -t "$session_name" WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
        if [[ -n "$tmux_workflow" && "$tmux_workflow" != "-WORKFLOW_NAME" ]]; then
            echo "$tmux_workflow"
            return
        fi
    fi

    # Try current tmux environment (requires being in tmux)
    if [[ -n "$TMUX" ]]; then
        local tmux_workflow=$(tmux $_tmux_flags showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
        if [[ -n "$tmux_workflow" && "$tmux_workflow" != "-WORKFLOW_NAME" ]]; then
            echo "$tmux_workflow"
            return
        fi
    fi

    # Fallback: discover most recent workflow folder (for scripts/tests running outside tmux)
    if [[ -d "$project_path/.workflow" ]]; then
        local latest=$(command ls -td "$project_path/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename 2>/dev/null)
        if [[ -n "$latest" ]]; then
            echo "$latest"
            return
        fi
    fi

    # No workflow found
    echo ""
}

# Get full path to current workflow
# Args:
#   $1: project_path (required)
#   $2: session_name (optional) - if provided, queries that session's env
get_current_workflow_path() {
    local project_path="$1"
    local session_name="${2:-}"
    local current=$(get_current_workflow "$project_path" "$session_name")

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
  pane_id: ""
  session: "$session"
  window: 0
  model: opus

agents: []
EOF

    echo "Created agents.yml: $agents_file"
}

# Add an agent to agents.yml
# If an agent with the same name already exists, updates its session/window fields
add_agent_to_yml() {
    local project_path="$1"
    local agent_name="$2"
    local agent_role="$3"
    local window_number="$4"
    local model="$5"
    local session="$6"
    local pane_id="${7:-}"

    local workflow_path=$(get_current_workflow_path "$project_path" "$session")
    if [[ -z "$workflow_path" ]]; then
        echo "Error: No current workflow" >&2
        return 1
    fi

    local agents_file="$workflow_path/agents.yml"

    if [[ ! -f "$agents_file" ]]; then
        echo "Error: agents.yml not found" >&2
        return 1
    fi

    # Check if agent already exists (from save_team_structure at Step 6)
    if grep -q "name: $agent_name" "$agents_file"; then
        # Update existing entry's session and window fields using Python for reliable YAML editing
        python3 -c "
import yaml, sys
with open('$agents_file', 'r') as f:
    data = yaml.safe_load(f)
for agent in data.get('agents', []):
    if agent.get('name') == '$agent_name':
        agent['pane_id'] = '$pane_id'
        agent['session'] = '$session'
        agent['window'] = $window_number
        agent['role'] = '$agent_role'
        agent['model'] = '$model'
        break
# Re-write using the same format as _write_agents_yml
with open('$agents_file', 'w') as f:
    f.write('# Agent Registry\n')
    f.write('# This file tracks all agents and their tmux locations\n\n')
    if 'pm' in data:
        pm = data['pm']
        f.write('pm:\n')
        for key in ['name', 'role', 'pane_id', 'session', 'window', 'model']:
            if key in pm:
                val = pm[key]
                if isinstance(val, str):
                    f.write(f'  {key}: \"{val}\"\n')
                else:
                    f.write(f'  {key}: {val}\n')
        f.write('\n')
    agents = data.get('agents', [])
    if not agents:
        f.write('agents: []\n')
    else:
        f.write('agents:\n')
        for agent in agents:
            first_key = True
            for key in ['name', 'role', 'pane_id', 'session', 'window', 'model']:
                if key in agent:
                    val = agent[key]
                    prefix = '  - ' if first_key else '    '
                    if isinstance(val, str) and val == '':
                        f.write(f'{prefix}{key}: \"\"\n')
                    elif isinstance(val, str):
                        f.write(f'{prefix}{key}: {val}\n')
                    else:
                        f.write(f'{prefix}{key}: {val}\n')
                    first_key = False
"
        echo "Updated $agent_name in agents.yml (window $window_number)"
        return 0
    fi

    # Check if agents: [] is empty and replace it with first agent
    if grep -q "^agents: \[\]" "$agents_file"; then
        # First agent - replace empty array
        sed -i '' "s/^agents: \[\]/agents:\\
  - name: $agent_name\\
    role: $agent_role\\
    pane_id: \"$pane_id\"\\
    session: \"$session\"\\
    window: $window_number\\
    model: $model/" "$agents_file"
    else
        # Additional agents - append to array
        cat >> "$agents_file" <<EOF
  - name: $agent_name
    role: $agent_role
    pane_id: "$pane_id"
    session: "$session"
    window: $window_number
    model: $model
EOF
    fi

    echo "Added $agent_name to agents.yml (window $window_number)"
}

# Save team structure to agents.yml and create agent files
# Reads existing agents.yml (preserves PM entry), appends new agents with empty session/window.
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

    local agents_file="$workflow_path/agents.yml"

    # Read existing agents.yml and remove the empty agents: [] line if present
    # We'll append new agents to the agents: section
    if [[ -f "$agents_file" ]]; then
        # If agents list is empty, replace it with a non-empty list
        if grep -q "^agents: \[\]" "$agents_file"; then
            sed -i '' "s/^agents: \[\]/agents:/" "$agents_file"
        fi
    else
        echo "Error: agents.yml not found at $agents_file" >&2
        return 1
    fi

    # Add each agent to agents.yml and create their files
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

        # Check if agent already exists — skip append if so (update role/model in place)
        if grep -q "name: $agent_name$" "$agents_file"; then
            # Agent already in agents.yml — update role and model via Python for reliable YAML editing
            python3 -c "
import yaml
with open('$agents_file', 'r') as f:
    data = yaml.safe_load(f)
for agent in data.get('agents', []):
    if agent.get('name') == '$agent_name':
        agent['role'] = '$agent_role'
        agent['model'] = '$agent_model'
        break
with open('$agents_file', 'w') as f:
    f.write('# Agent Registry\n')
    f.write('# This file tracks all agents and their tmux locations\n\n')
    if 'pm' in data:
        pm = data['pm']
        f.write('pm:\n')
        for key in ['name', 'role', 'pane_id', 'session', 'window', 'model']:
            if key in pm:
                val = pm[key]
                if isinstance(val, str):
                    f.write(f'  {key}: \\\"{val}\\\"\n')
                else:
                    f.write(f'  {key}: {val}\n')
        f.write('\n')
    agents = data.get('agents', [])
    if not agents:
        f.write('agents: []\n')
    else:
        f.write('agents:\n')
        for agent in agents:
            first_key = True
            for key in ['name', 'role', 'pane_id', 'session', 'window', 'model']:
                if key in agent:
                    val = agent[key]
                    prefix = '  - ' if first_key else '    '
                    if isinstance(val, str) and val == '':
                        f.write(f'{prefix}{key}: \\\"\\\"\n')
                    elif isinstance(val, str):
                        f.write(f'{prefix}{key}: {val}\n')
                    else:
                        f.write(f'{prefix}{key}: {val}\n')
                    first_key = False
"
        else
            # Append new agent to agents.yml with empty pane_id/session/window
            cat >> "$agents_file" <<EOF
  - name: $agent_name
    role: $agent_role
    pane_id: ""
    session: ""
    window: ""
    model: $agent_model
EOF
        fi

        # Create agent files (identity.yml, instructions.md, agent-tasks.md, etc.)
        # Pass _YATO_WORKFLOW_NAME so init-agent-files.sh (called by agent_manager) targets the right workflow
        cd "$WORKFLOW_UTILS_DIR/.." && _YATO_WORKFLOW_NAME="$(basename "$workflow_path")" uv run python lib/agent_manager.py init-files "$agent_name" "$agent_role" -p "$project_path" -m "$agent_model"
    done

    echo "Saved team structure to: $agents_file"
}
