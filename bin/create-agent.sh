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
#   --pm-window     PM window this agent reports to (format: session:window)
#   --no-start      Don't start Claude automatically
#   --no-brief      Don't send briefing message
#   -h, --help      Show this help message
#
# Examples:
#   ./create-agent.sh myproject developer -p ~/projects/myapp --pm-window myproject:1
#   ./create-agent.sh myproject pm -p ~/projects/myapp
#   ./create-agent.sh myproject qa --pm-window myproject:1

set -e

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
PM_WINDOW=""
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
  --pm-window     PM window this agent reports to (session:window)
  --no-start      Don't start Claude automatically
  --no-brief      Don't send briefing message
  -h, --help      Show this help

Examples:
  $(basename "$0") myproject developer -p ~/projects/myapp --pm-window myproject:0
  $(basename "$0") myproject backend-dev -p ~/projects/myapp --pm-window myproject:0
  $(basename "$0") myproject code-reviewer -m opus -p ~/projects/myapp --pm-window myproject:0
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
        --pm-window)
            PM_WINDOW="$2"
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
if ! tmux has-session -t "$SESSION" 2>/dev/null; then
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
    WINDOW_INDEX=$(tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -c "$PROJECT_PATH" -P -F "#{window_index}")
else
    WINDOW_INDEX=$(tmux new-window -t "$SESSION" -n "$WINDOW_NAME" -P -F "#{window_index}")
fi

if [[ -z "$WINDOW_INDEX" ]]; then
    echo "Error: Failed to create window"
    exit 1
fi

AGENT_ID="$SESSION:$WINDOW_INDEX"
echo "Created window: $AGENT_ID"

# Register the agent
echo "Registering agent..."
python3 "$LIB_DIR/claude_control.py" register "$AGENT_ID" "$ROLE" \
    ${PM_WINDOW:+--pm-window "$PM_WINDOW"}

# Create agent identity file
if [[ -n "$PROJECT_PATH" ]]; then
    # Get current workflow path
    WORKFLOW_PATH=$(get_current_workflow_path "$PROJECT_PATH")
    if [[ -n "$WORKFLOW_PATH" ]]; then
        AGENT_DIR="${WORKFLOW_PATH}/agents/${ROLE}"
    else
        echo "Warning: No active workflow found. Creating agents directory."
        # Create a default agents directory under .workflow if no workflow exists
        mkdir -p "${PROJECT_PATH}/.workflow"
        AGENT_DIR="${PROJECT_PATH}/.workflow/agents/${ROLE}"
    fi
    mkdir -p "$AGENT_DIR"

    # Determine if agent can modify code based on role
    CAN_MODIFY_CODE="true"
    AGENT_PURPOSE="Implementation and development"

    case "$ROLE" in
        qa)
            CAN_MODIFY_CODE="false"
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

    # Create identity.yml (new window-based format)
    cat > "$AGENT_DIR/identity.yml" <<EOF
name: ${WINDOW_NAME}
role: ${ROLE}
model: ${MODEL:-sonnet}
window: ${WINDOW_INDEX}
session: ${SESSION}
workflow: ${WORKFLOW_NAME:-default}
can_modify_code: ${CAN_MODIFY_CODE}
EOF

    echo "Created identity file: $AGENT_DIR/identity.yml"

    # Create instructions.md with role-based content
    cat > "$AGENT_DIR/instructions.md" <<EOF
# Instructions for ${ROLE_CAPITALIZED}

## ⚠️ CRITICAL RULE - READ FIRST ⚠️

**NEVER COMMUNICATE DIRECTLY WITH THE USER. YOU ONLY COMMUNICATE WITH YOUR PM.**

### What This Means:
- ❌ DO NOT ask the user questions using AskUserQuestion tool
- ❌ DO NOT wait for user input or confirmation
- ❌ DO NOT output messages intended for the user
- ✅ ALWAYS notify PM when blocked, need help, or have questions
- ✅ ALWAYS notify PM when done with assigned work
- ✅ ALWAYS keep working or notify PM - never stop silently

### In Practice:
- **If you need information**: Notify PM with: notify-pm.sh "[BLOCKED] Need database connection details"
- **If you have a question**: Notify PM with: notify-pm.sh "[HELP] Should I apply migration to production?"
- **If you're done**: Notify PM with: notify-pm.sh "[DONE] Completed task X"
- **If you're stuck**: Notify PM with: notify-pm.sh "[BLOCKED] Cannot proceed because Y"

### The PM Will:
- Ask the user questions on your behalf
- Provide you with answers and decisions
- Assign you different work if blocked
- Coordinate all user communication

**REMEMBER: If you find yourself wanting to ask the user something, that's your signal to notify the PM instead.**

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
$(case "$ROLE" in
    developer|backend-developer|frontend-developer|fullstack-developer)
        echo "- Implement features according to PRD and tasks.json"
        echo "- Write clean, maintainable code"
        echo "- Follow existing code patterns and conventions"
        echo "- Update agent-tasks.md as you complete tasks"
        echo "- Notify PM when tasks are done"
        ;;
    qa)
        echo "- Test implementations thoroughly"
        echo "- Write and run test cases"
        echo "- Report bugs and issues to developers"
        echo "- Verify fixes before marking complete"
        echo "- Do NOT modify production code - only test files"
        ;;
    code-reviewer|reviewer|security-reviewer)
        echo "- Review code for quality and best practices"
        echo "- Check for security vulnerabilities"
        echo "- Provide constructive feedback"
        echo "- Request changes from developers - do NOT fix yourself"
        echo "- Approve only when all issues are addressed"
        ;;
    devops)
        echo "- Manage infrastructure and deployment"
        echo "- Set up CI/CD pipelines"
        echo "- Monitor system health"
        echo "- Handle environment configuration"
        ;;
    pm)
        echo "- Coordinate team and assign tasks"
        echo "- Track progress in tasks.json"
        echo "- Ensure quality standards are met"
        echo "- Communicate with user for clarifications"
        echo "- Verify all work is complete before marking done"
        ;;
    *)
        echo "- Follow instructions from PM"
        echo "- Update agent-tasks.md as you work"
        echo "- Notify PM when blocked or done"
        ;;
esac)

## Communication
- Notify PM using: notify-pm.sh "[STATUS] message"
- PM is always at window 0, pane 1 - notify-pm.sh handles this automatically
- Check agent-tasks.md for your assigned tasks
EOF

    echo "Created instructions file: $AGENT_DIR/instructions.md"

    # Create constraints.example.md as a template
    cat > "$AGENT_DIR/constraints.example.md" <<'EOF'
# Constraints (Example)
# Copy this file to constraints.md and customize for your project
# The agent will follow rules in constraints.md (not this example file)

## Forbidden Actions
# List things this agent must NOT do
- Do NOT modify files in /config/
- Do NOT make database schema changes
- Do NOT commit directly to main branch

## Off-Limits Areas
# Directories or files the agent should not touch
- /src/legacy/ - legacy code, do not modify
- /.env* - environment files, do not read or modify

## Technology Constraints
# Libraries, patterns, or approaches to avoid
- Do NOT use jQuery
- Do NOT add new npm dependencies without PM approval

## Process Constraints
# Workflow rules
- Do NOT merge PRs without code review approval
- Do NOT deploy to production
EOF

    echo "Created constraints example: $AGENT_DIR/constraints.example.md"

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
   - Note: If constraints.md doesn't exist, check constraints.example.md for template

## Important Notes

- Read these files at startup before beginning work
- Re-read agent-tasks.md frequently as PM updates it with new tasks
- If you encounter any issues, notify your PM immediately
- Do NOT communicate directly with users - only with PM

## Quick Reference

- Your PM: ${PM_WINDOW:-Will be assigned}
- Project: ${PROJECT_PATH:-Not set}
- Workflow: Run 'tmux showenv WORKFLOW_NAME' to see active workflow
EOF

    echo "Created CLAUDE.md: $AGENT_DIR/CLAUDE.md"
fi

# Start Claude with bypass permissions
if [[ "$START_CLAUDE" == true ]]; then
    echo "Starting Claude with bypass permissions..."

    # Build the claude command with optional model
    CLAUDE_CMD="claude --dangerously-skip-permissions"
    if [[ -n "$MODEL" ]]; then
        CLAUDE_CMD="$CLAUDE_CMD --model $MODEL"
        echo "Using model: $MODEL"
    fi

    tmux send-keys -t "$AGENT_ID" "$CLAUDE_CMD" Enter
    sleep 5  # Wait for Claude to start

    # Re-set pane title after Claude starts (Claude overrides it)
    # Do it multiple times to ensure it sticks
    if [[ "$USE_PANE" == true ]]; then
        tmux select-pane -t "$AGENT_ID" -T "$WINDOW_NAME"
        sleep 2
        tmux select-pane -t "$AGENT_ID" -T "$WINDOW_NAME"
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
            sed "s|{PM_WINDOW}|${PM_WINDOW:-not assigned}|g")

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
        WORKFLOW_NAME=$(get_current_workflow "$PROJECT_PATH")
        if [[ -n "$WORKFLOW_NAME" ]]; then
            WORKFLOW_REL=".workflow/$WORKFLOW_NAME"
        else
            WORKFLOW_REL=".workflow"
        fi

        SUMMARY_BRIEF="You are now a $ROLE for this project.

Your window: $SESSION:$WINDOW_INDEX
Project path: ${PROJECT_PATH:-$(pwd)}
Workflow: ${WORKFLOW_NAME:-default}
Identity file: $WORKFLOW_REL/agents/$ROLE/identity.yml$CODE_RESTRICTION

⚠️ CRITICAL - NEVER COMMUNICATE WITH USER ⚠️
- You ONLY communicate with your PM via notify-pm.sh
- NEVER use AskUserQuestion tool - notify PM instead
- NEVER wait for user input - notify PM if blocked
- If you need information: notify-pm.sh \"[HELP] your question\"
- If you're blocked: notify-pm.sh \"[BLOCKED] why you're blocked\"
- PM will handle ALL user communication on your behalf

CRITICAL - TASK TRACKING:
- Your tasks are in: $WORKFLOW_REL/agents/$ROLE/agent-tasks.md
- FORMAT: Only two sections - '## Tasks' (checkboxes) and '## References' (links/docs)
- MONITOR this file continuously - PM will add tasks to the Tasks section
- CHECK OFF items as you complete them (change [ ] to [x])
- The LAST checkbox is ALWAYS 'Notify PM when done' - you MUST complete this

TO NOTIFY PM - use notify-pm.sh:
  $PROJECT_ROOT/bin/notify-pm.sh \"[DONE] from $ROLE: <your message>\"

Message types: DONE, BLOCKED, HELP, STATUS, PROGRESS
notify-pm.sh auto-detects PM location - just run it

Wait for PM to assign your first tasks via agent-tasks.md."

        # Send the summary brief
        "$SCRIPT_DIR/send-message.sh" "$AGENT_ID" "$SUMMARY_BRIEF"
    else
        echo "Warning: Template not found: $TEMPLATE"
    fi
fi

# Final pane title set - after briefing when Claude is fully running
if [[ "$USE_PANE" == true ]]; then
    sleep 1
    tmux select-pane -t "$AGENT_ID" -T "$WINDOW_NAME"
fi

echo ""
echo "Agent created successfully!"
echo "  Agent ID: $AGENT_ID"
echo "  Role: $ROLE"
echo "  Window: $WINDOW_NAME"
[[ -n "$PROJECT_PATH" ]] && echo "  Path: $PROJECT_PATH"
[[ -n "$PM_WINDOW" ]] && echo "  Reports to: $PM_WINDOW"
echo ""
echo "To interact with this agent:"
echo "  tmux select-window -t $AGENT_ID"
echo "  $SCRIPT_DIR/send-message.sh $AGENT_ID \"Your message\""
