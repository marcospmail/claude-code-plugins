#!/bin/bash

# PM Oversight Loop Setup Script
# Uses ralph-wiggum plugin for loop mechanism
# Creates PM agent folder and state file for continuous oversight

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
YATO_PATH="$(cd "$(dirname "$0")/.." && pwd)"

# Source workflow utilities
source "$SCRIPT_DIR/workflow-utils.sh"

# Parse arguments
PROJECT_PATH=""
MAX_ITERATIONS=100
SESSION=""

print_usage() {
  cat << 'EOF'
PM Oversight Loop Setup

USAGE:
  setup-pm-loop.sh -p <project-path> [-s <session>] [--max-iterations <n>]

OPTIONS:
  -p, --project      Project path (required)
  -s, --session      Tmux session name (auto-detected if not provided)
  --max-iterations   Max oversight iterations (default: 100, 0 = unlimited)
  -h, --help         Show this help

DESCRIPTION:
  Sets up a PM agent in a continuous oversight loop using ralph-wiggum plugin.
  The PM will:
  - Check agent agent-tasks.md files
  - Send commands to agents via send-message.sh
  - Verify task completion before signaling done
  - Continue looping until all work is verified complete

COMPLETION:
  The PM must output: <promise>ALL TASKS VERIFIED COMPLETE</promise>
  when all agent work has been verified done.

EXAMPLE:
  setup-pm-loop.sh -p ~/projects/myapp
  setup-pm-loop.sh -p /tmp/test-app -s test-session --max-iterations 50
EOF
}

while [[ $# -gt 0 ]]; do
  case $1 in
    -h|--help)
      print_usage
      exit 0
      ;;
    -p|--project)
      PROJECT_PATH="$2"
      shift 2
      ;;
    -s|--session)
      SESSION="$2"
      shift 2
      ;;
    --max-iterations)
      MAX_ITERATIONS="$2"
      shift 2
      ;;
    *)
      echo "Unknown option: $1" >&2
      print_usage
      exit 1
      ;;
  esac
done

# Validate project path
if [[ -z "$PROJECT_PATH" ]]; then
  echo "Error: Project path is required (-p)" >&2
  print_usage
  exit 1
fi

if [[ ! -d "$PROJECT_PATH" ]]; then
  echo "Error: Project path does not exist: $PROJECT_PATH" >&2
  exit 1
fi

# Auto-detect session if not provided
if [[ -z "$SESSION" ]]; then
  SESSION=$(tmux display-message -p '#S' 2>/dev/null || echo "")
  if [[ -z "$SESSION" ]]; then
    echo "Error: Could not detect tmux session. Provide -s option." >&2
    exit 1
  fi
fi

# Get current workflow path
WORKFLOW_PATH=$(get_current_workflow_path "$PROJECT_PATH")
if [[ -z "$WORKFLOW_PATH" ]]; then
  echo "Error: No current workflow. Create one first." >&2
  exit 1
fi

# Create PM folder structure inside workflow
PM_DIR="$WORKFLOW_PATH/agents/pm"
mkdir -p "$PM_DIR"

# Ensure .claude directory exists for symlink
mkdir -p "$PROJECT_PATH/.claude"

# Get current window for PM agent ID
PM_WINDOW=$(tmux display-message -p '#{window_index}' 2>/dev/null || echo "0")
PM_AGENT_ID="$SESSION:0.$PM_WINDOW"

# Create PM identity.yml
cat > "$PM_DIR/identity.yml" << EOF
# Agent Identity
name: pm
role: project-manager
agent_id: $PM_AGENT_ID
purpose: Team oversight and quality verification
description: |
  Project Manager running in oversight loop.
  Continuously monitors agent progress and verifies task completion.
  Commands agents via send-message.sh, reads agent-tasks.md files.
can_modify_code: false
model: sonnet
created_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
loop_enabled: true
EOF

echo "Created PM identity: $PM_DIR/identity.yml"

# Create PM oversight prompt
OVERSIGHT_PROMPT=$(cat << 'PROMPT_EOF'
You are the Project Manager in an oversight loop. Your job is to verify all agent work is complete.

## Your Tools
- Read agent progress files: Read .workflow/agents/*/agent-tasks.md
- Send commands: ${CLAUDE_PLUGIN_ROOT}/bin/send-message.sh <session>:<window>.<pane> "message"
- Check agent output: tmux capture-pane -t <session>:<window>.<pane> -p | tail -50

## Oversight Protocol
1. Read each agent's agent-tasks.md to check task status
2. If tasks are incomplete, send reminders or instructions
3. If agents are blocked, help unblock them
4. Verify completed work meets quality standards
5. Only when ALL tasks are verified complete, output completion

## Completion Signal
When ALL agent tasks are verified complete, output:
<promise>ALL TASKS VERIFIED COMPLETE</promise>

Do NOT output this unless you have verified every agent's work is done!
PROMPT_EOF
)

# Create ralph-wiggum compatible state file in workflow folder
RALPH_STATE_FILE="$WORKFLOW_PATH/ralph-loop.local.md"
cat > "$RALPH_STATE_FILE" << EOF
---
active: true
iteration: 1
max_iterations: $MAX_ITERATIONS
completion_promise: "ALL TASKS VERIFIED COMPLETE"
started_at: "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
workflow: "$(basename "$WORKFLOW_PATH")"
---

$OVERSIGHT_PROMPT
EOF

echo "Created ralph-wiggum state: $RALPH_STATE_FILE"

# Create symlink so ralph-wiggum plugin can find it
SYMLINK_TARGET="$PROJECT_PATH/.claude/ralph-loop.local.md"
rm -f "$SYMLINK_TARGET" 2>/dev/null || true
ln -s "$RALPH_STATE_FILE" "$SYMLINK_TARGET"
echo "Created symlink: $SYMLINK_TARGET -> $RALPH_STATE_FILE"

# Output activation message
WORKFLOW_NAME=$(basename "$WORKFLOW_PATH")
cat << EOF

PM Oversight Loop Activated!

Workflow: $WORKFLOW_NAME
Session: $SESSION
Project: $PROJECT_PATH
Max iterations: $(if [[ $MAX_ITERATIONS -gt 0 ]]; then echo $MAX_ITERATIONS; else echo "unlimited"; fi)

The PM will now run in a continuous loop (powered by ralph-wiggum):
1. Check agent progress files
2. Send commands to agents as needed
3. Verify task completion
4. Continue until all work is done

To complete the loop, PM must output:
  <promise>ALL TASKS VERIFIED COMPLETE</promise>

To monitor: cat $RALPH_STATE_FILE

EOF
