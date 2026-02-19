#!/bin/bash
# init-agent-files.sh - Create agent folder and files (without tmux window)
#
# This script creates the agent's configuration files before the tmux window exists.
# Called by save_team_structure after team.yml is created.
# When create-agent.sh later creates the window, it will update identity.yml with the window number.
#
# Usage: ./init-agent-files.sh <project_path> <agent_name> <role> <model>
#
# Creates:
#   .workflow/<workflow>/agents/<agent_name>/
#   ├── identity.yml        (window field empty until tmux window created)
#   ├── instructions.md
#   ├── constraints.example.md
#   ├── CLAUDE.md
#   └── agent-tasks.md      (empty template ready for PM to assign tasks)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"

# Source workflow utilities
source "$SCRIPT_DIR/workflow-utils.sh"

# Arguments
PROJECT_PATH="${1:-}"
AGENT_NAME="${2:-}"
ROLE="${3:-}"
MODEL="${4:-sonnet}"

if [[ -z "$PROJECT_PATH" ]] || [[ -z "$AGENT_NAME" ]] || [[ -z "$ROLE" ]]; then
    echo "Usage: $(basename "$0") <project_path> <agent_name> <role> [model]"
    echo ""
    echo "Example: $(basename "$0") ~/myproject dev developer sonnet"
    exit 1
fi

# Expand project path
PROJECT_PATH=$(eval echo "$PROJECT_PATH")

# Get current workflow path
WORKFLOW_PATH=$(get_current_workflow_path "$PROJECT_PATH")
if [[ -z "$WORKFLOW_PATH" ]]; then
    echo "Error: No active workflow found in $PROJECT_PATH"
    exit 1
fi

WORKFLOW_NAME=$(get_current_workflow "$PROJECT_PATH")

# Create agent directory using agent name (not role) to support multiple agents of same role
AGENT_DIR="${WORKFLOW_PATH}/agents/${AGENT_NAME}"
mkdir -p "$AGENT_DIR"

# Create capitalized versions for display
ROLE_CAPITALIZED=$(echo "$ROLE" | sed 's/\b\(.\)/\u\1/g')
NAME_CAPITALIZED=$(echo "$AGENT_NAME" | sed 's/\b\(.\)/\u\1/g')

# Determine if agent can modify code based on role
CAN_MODIFY_CODE="true"
AGENT_PURPOSE="Implementation and development"

case "$ROLE" in
    qa)
        CAN_MODIFY_CODE="test-only"
        AGENT_PURPOSE="Testing and quality assurance"
        ;;
    code-reviewer|reviewer|security-reviewer)
        CAN_MODIFY_CODE="false"
        AGENT_PURPOSE="Code review and security analysis"
        ;;
    developer|backend-developer|frontend-developer|fullstack-developer)
        CAN_MODIFY_CODE="true"
        AGENT_PURPOSE="Implementation and development"
        ;;
    devops)
        CAN_MODIFY_CODE="true"
        AGENT_PURPOSE="Infrastructure and deployment"
        ;;
    designer)
        CAN_MODIFY_CODE="false"
        AGENT_PURPOSE="Design and user experience"
        ;;
    *)
        # Default: developers can modify, others cannot
        if [[ "$ROLE" == *"developer"* ]] || [[ "$ROLE" == *"dev"* ]]; then
            CAN_MODIFY_CODE="true"
            AGENT_PURPOSE="Development and implementation"
        else
            CAN_MODIFY_CODE="false"
            AGENT_PURPOSE="Support and analysis"
        fi
        ;;
esac

# Create identity.yml (window field empty - will be filled by create-agent.sh)
cat > "$AGENT_DIR/identity.yml" <<EOF
name: ${AGENT_NAME}
role: ${ROLE}
model: ${MODEL}
window:
session:
workflow: ${WORKFLOW_NAME}
can_modify_code: ${CAN_MODIFY_CODE}
EOF

# Build role description and responsibilities before heredoc
if [[ "$CAN_MODIFY_CODE" == "true" ]]; then
    ROLE_DESCRIPTION="You are responsible for writing and modifying code."
elif [[ "$CAN_MODIFY_CODE" == "test-only" ]]; then
    ROLE_DESCRIPTION="You CAN write and modify TEST files (e2e/, tests/, __tests__/, *.spec.*, *.test.*).
You CANNOT modify production code (src/, lib/, app/). Test files only!"
else
    ROLE_DESCRIPTION="You review, test, or analyze code but do NOT modify it directly.
Any changes must be requested from developers."
fi

case "$ROLE" in
    developer|backend-developer|frontend-developer|fullstack-developer)
        RESPONSIBILITIES="- Implement features according to PRD and tasks.json
- Write clean, maintainable code
- Follow existing code patterns and conventions
- Update agent-tasks.md as you complete tasks
- Notify PM when tasks are done"
        ;;
    qa)
        RESPONSIBILITIES="- Test implementations thoroughly
- Write and run test cases (you CAN create/modify test files in e2e/, tests/, __tests__/)
- Report bugs and issues to developers
- Verify fixes before marking complete
- Do NOT modify production code (src/, lib/, app/) - TEST FILES ONLY
- You are ALLOWED to use Write/Edit tools for test files"
        ;;
    code-reviewer|reviewer|security-reviewer)
        RESPONSIBILITIES="- Review code for quality and best practices
- Check for security vulnerabilities
- Provide constructive feedback
- Request changes from developers - do NOT fix yourself
- Approve only when all issues are addressed"
        ;;
    devops)
        RESPONSIBILITIES="- Manage infrastructure and deployment
- Set up CI/CD pipelines
- Monitor system health
- Handle environment configuration"
        ;;
    *)
        RESPONSIBILITIES="- Follow instructions from PM
- Update agent-tasks.md as you work
- Notify PM when blocked or done"
        ;;
esac

# Create instructions.md with role-based content (positive guidance only, no NEVER rules)
cat > "$AGENT_DIR/instructions.md" <<EOF
# Instructions for ${NAME_CAPITALIZED} (${ROLE_CAPITALIZED})

## Role
${AGENT_PURPOSE}

## Description
${ROLE_DESCRIPTION}

## Responsibilities
${RESPONSIBILITIES}

## Communication
- Notify PM using: notify-pm.sh "[STATUS] message"
- PM is always at window 0, pane 1 - notify-pm.sh handles this automatically
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

Example:
\`\`\`bash
# Limited retries with PM notification
for i in 1 2 3 4 5; do
  if [[ -f "expected_file.md" ]]; then break; fi
  sleep \$((i * 30))
done
if [[ ! -f "expected_file.md" ]]; then
  notify-pm.sh "[BLOCKED] Waited 5 times for expected_file.md - still missing"
fi
\`\`\`

Your PM can help resolve blocking dependencies. Notify early.
EOF

# Create constraints.md with system constraints + customizable section
if [[ "$ROLE" == "pm" ]]; then
    cat > "$AGENT_DIR/constraints.md" <<'EOF'
# PM Constraints

## System Constraints

- NEVER communicate directly with the user
- DO NOT ask the user questions using AskUserQuestion tool
- DO NOT wait for user input or confirmation
- DO NOT output messages intended for the user
- NEVER stop working silently - always notify PM
- DO NOT enter infinite polling loops when waiting for dependencies

## PM-Specific Constraints

- You CANNOT modify any code files
- Do NOT write implementation code
- Do NOT run tests directly (delegate to QA agent)
- Do NOT make git commits (delegate to agents)
- NEVER call cancel-checkin.sh - the check-in loop stops AUTOMATICALLY when all tasks are completed
  (only the USER can stop the loop early via /cancel-checkin if they choose to)
- NEVER skip updating tasks.json before modifying agent-tasks.md
- NEVER write to agent-tasks.md without a corresponding entry in tasks.json

## Required Actions
- ALWAYS delegate implementation to agents
- ALWAYS update tasks.json when tasks change status
- ALWAYS provide specific, actionable feedback
- ALWAYS use `/send-to-agent <agent-name> "message"` to communicate with agents
EOF
else
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
fi

# Create CLAUDE.md with references to all agent files
cat > "$AGENT_DIR/CLAUDE.md" <<EOF
# Agent Configuration

This file contains references to all your configuration and task files. Read these files in order to understand your role and responsibilities.

## Required Reading (in order)

1. **Identity** - Read first to understand who you are
   - File: [identity.yml](./identity.yml)
   - Contains: Your role, capabilities, and model

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

- Your PM: Window 0, Pane 1
- Project: ${PROJECT_PATH}
- Workflow: ${WORKFLOW_NAME}
EOF

# Create empty agent-tasks.md template ready for PM to assign tasks
cat > "$AGENT_DIR/agent-tasks.md" <<EOF
## Tasks

## References
EOF

echo "Created agent files for '$AGENT_NAME' at: $AGENT_DIR"
