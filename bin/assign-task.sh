#!/bin/bash
# assign-task.sh - Assign tasks to an agent's agent-tasks.md file
# Usage: ./assign-task.sh <project_path> <agent_name> "<task_description>"
#
# This script:
# 1. Creates the agent's agent-tasks.md if it doesn't exist
# 2. Appends a new task batch with checklist items
# 3. Always adds "Notify PM" as the final item
#
# Example:
#   ./assign-task.sh ~/projects/myapp developer "Implement login form
#   - Create LoginForm.jsx component
#   - Add form validation
#   - Connect to auth API"

set -e

PROJECT_PATH="${1:-$(pwd)}"
AGENT_NAME="${2:-}"
TASK_DESCRIPTION="${3:-}"

if [[ -z "$AGENT_NAME" ]] || [[ -z "$TASK_DESCRIPTION" ]]; then
    echo "Usage: $(basename "$0") <project_path> <agent_name> \"<task_description>\""
    echo ""
    echo "Example:"
    echo "  $(basename "$0") ~/projects/myapp developer \"Implement login form"
    echo "  - Create LoginForm.jsx component"
    echo "  - Add form validation\""
    exit 1
fi

# Source workflow utilities
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/workflow-utils.sh"

# Get current workflow path (use workflow folder, not root)
WORKFLOW_PATH=$(get_current_workflow_path "$PROJECT_PATH")
if [[ -z "$WORKFLOW_PATH" ]]; then
    # Fallback to root if no active workflow
    WORKFLOW_PATH="$PROJECT_PATH/.workflow"
fi

# Validate agent exists in team.yml (if team.yml exists)
TEAM_FILE="$WORKFLOW_PATH/team.yml"
if [[ -f "$TEAM_FILE" ]]; then
    if ! grep -q "^  - name: $AGENT_NAME" "$TEAM_FILE"; then
        echo "WARNING: Agent '$AGENT_NAME' not found in team.yml"
        echo "Available agents:"
        grep "^  - name:" "$TEAM_FILE" | sed 's/.*name: /  - /'
        echo ""
        echo "Continuing anyway (agent may be created later)..."
    fi
fi

AGENTS_DIR="$WORKFLOW_PATH/agents"
AGENT_DIR="$AGENTS_DIR/$AGENT_NAME"
PROGRESS_FILE="$AGENT_DIR/agent-tasks.md"

mkdir -p "$AGENT_DIR"

# Get current timestamp
TIMESTAMP=$(date "+%Y-%m-%d %H:%M:%S")

# Create file with strict format if it doesn't exist
if [[ ! -f "$PROGRESS_FILE" ]]; then
    cat > "$PROGRESS_FILE" << EOF
## Tasks

## References
EOF
fi

# Parse task description and convert to checklist
# If lines start with "- ", convert to "[ ] "
CHECKLIST=$(echo "$TASK_DESCRIPTION" | sed 's/^- /[ ] /')

# Insert tasks BEFORE the ## References section
# This maintains the strict format: Tasks first, References last
TEMP_FILE=$(mktemp)
awk -v tasks="$CHECKLIST" '
    /^## References/ {
        print tasks
        print "[ ] **Notify PM when done** (use: notify-pm.sh DONE \"Completed: <summary>\")"
        print ""
    }
    { print }
' "$PROGRESS_FILE" > "$TEMP_FILE"
mv "$TEMP_FILE" "$PROGRESS_FILE"

echo "Task assigned to $AGENT_NAME"
echo "Progress file: $PROGRESS_FILE"
