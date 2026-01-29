# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Project Overview

Yato (Yet Another Tmux Orchestrator) is a Claude Code plugin that enables multiple Claude agents to work autonomously across tmux sessions. It provides tools for deploying agent teams (PM, Developer, QA), scheduling check-ins, and coordinating work across projects.

## Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                        Orchestrator                              │
│  (You - coordinates all projects and teams)                      │
└────────────────────────────┬────────────────────────────────────┘
                             │
         ┌───────────────────┼───────────────────┐
         ▼                   ▼                   ▼
┌─────────────────┐  ┌─────────────────┐  ┌─────────────────┐
│  Project Manager │  │  Project Manager │  │  Project Manager │
│  (quality gate)  │  │                  │  │                  │
└────────┬────────┘  └────────┬────────┘  └────────┬────────┘
         │                    │                    │
    ┌────┴────┐          ┌────┴────┐          ┌────┴────┐
    ▼         ▼          ▼         ▼          ▼         ▼
┌───────┐ ┌───────┐  ┌───────┐ ┌───────┐  ┌───────┐ ┌───────┐
│  Dev  │ │  QA   │  │  Dev  │ │  Dev  │  │  Dev  │ │  QA   │
└───────┘ └───────┘  └───────┘ └───────┘  └───────┘ └───────┘
    ↑         ↑          ↑         ↑          ↑         ↑
    └─────────┴──────────┴─────────┴──────────┴─────────┘
                    notify-pm.sh (reports up)
```

### Key Components

| Directory | Purpose |
|-----------|---------|
| `lib/` | Python modules - core orchestration logic |
| `bin/` | Shell scripts - agent communication and management |
| `commands/` | Claude Code slash commands (`/orc-*`) |
| `agents/` | Agent role definitions (pm.md, developer.md, qa.md) |
| `templates/` | Briefing templates for agents |
| `.yato/` | Runtime state (registry.json, checkins.json) |

### Python Module Hierarchy

```
lib/
├── orchestrator.py      # High-level API: init, deploy, status
├── claude_control.py    # CLI interface: status, list, send, read, team
├── session_registry.py  # Agent registry: Agent class, JSON persistence
├── tmux_utils.py        # Tmux operations: sessions, windows, panes
└── project_planner.py   # Project planning utilities
```

**Dependency flow**: `orchestrator.py` → `session_registry.py` + `tmux_utils.py`

### Data Flow

1. **Commands** (`commands/*.md`) invoke Python CLI or shell scripts
2. **Python CLI** (`lib/claude_control.py`) manages agent lifecycle
3. **Shell scripts** (`bin/*.sh`) handle tmux communication
4. **Registry** (`.yato/registry.json`) tracks all agents
5. **Check-ins** (`.yato/checkins.json`) schedules oversight

## Common Commands

### Running the CLI
```bash
# Agent status
python3 lib/claude_control.py status

# List tmux sessions/windows
python3 lib/claude_control.py list -v

# Initialize project with PM + developer
python3 lib/orchestrator.py init <session> -p <path>

# Deploy team
python3 lib/orchestrator.py deploy <session> -p <path> -c team.json
```

### Shell Scripts
```bash
# Send message to agent
bin/send-message.sh <session>:<window> "message"

# Create agent
bin/create-agent.sh <session> <role> -p <path> --pm-window <session>:<window>

# Schedule check-in
bin/schedule-checkin.sh <minutes> "<note>" [target_window]

# Cancel check-ins
bin/cancel-checkin.sh
```

## Key Concepts

### Agent Registry
Agents are tracked in `.yato/registry.json`:
```json
{
  "agents": [
    {
      "agent_id": "myproject:1",
      "session_name": "myproject",
      "window_index": 1,
      "role": "pm",
      "pm_window": null,
      "status": "active"
    }
  ]
}
```

### Check-in System
Scheduled check-ins in `.yato/checkins.json`:
```json
{
  "checkins": [
    {
      "id": "123456",
      "status": "pending",
      "scheduled_for": "2026-01-23T15:30:00",
      "note": "Check developer progress",
      "target": "myproject:0"
    }
  ]
}
```

### Workflow System
Projects use `.workflow/` directories:
```
project/.workflow/
├── current                    # Active workflow name
└── 001-feature-name/
    ├── status.yml             # Workflow status (includes initial_request)
    ├── prd.md                 # Requirements
    ├── tasks.json             # Generated tasks (JSON format)
    └── agents/                # Agent configs
```

**status.yml** contains all workflow metadata:
```yaml
status: in-progress
title: "Add hourly cron"
initial_request: |
  User's original request goes here...
folder: "001-add-hourly-cron"
checkin_interval_minutes: 15
session: "myproject"
```

## Agent Communication

### Orchestrator → Agent
```bash
bin/send-message.sh session:window "Your message"
```

### Agent → PM (Two-way)
Agents report up using notification types:
```bash
bin/notify-pm.sh DONE "Completed task"
bin/notify-pm.sh BLOCKED "Waiting for X"
bin/notify-pm.sh HELP "Need guidance"
bin/notify-pm.sh STATUS "50% complete"
bin/notify-pm.sh PROGRESS "3 of 5 tasks done"
```

## YATO_PATH Variable

Always set this at the start of Yato sessions:
```bash
YATO_PATH="$HOME/dev/tools/yato"
```

## Tmux Patterns

### Creating Windows with Correct Directory
```bash
# ALWAYS use -c flag to set directory
tmux new-window -t session -n "name" -c "/path/to/project"
```

### Verifying Command Execution
```bash
tmux send-keys -t session:window "command" Enter
sleep 2
tmux capture-pane -t session:window -p | tail -20
```

### Agent Target Format
- Window-based: `session:window` (e.g., `myproject:1`)
- Pane-based: `session:window.pane` (e.g., `myproject:0.1`)

### Bash Command Chaining (IMPORTANT)

When running multiple bash commands, **always chain them on a single line** using `&&` or `;`. Never use newlines between commands.

**CORRECT:**
```bash
# Chain with && (run if previous succeeds)
tmux capture-pane -t "$SESSION:1" -p | tail -30 && echo "=== Next ===" && tmux capture-pane -t "$SESSION:2" -p | tail -20

# Chain with ; (run regardless)
git status; git diff --stat; echo "Done"
```

**INCORRECT (causes parsing errors):**
```bash
# BAD: Newlines break command parsing
tmux capture-pane -t "$SESSION:1" -p | tail -30
echo "=== Next ==="
tmux capture-pane -t "$SESSION:2" -p | tail -20
```

The incorrect approach causes errors like `tail: echo: No such file or directory` because tmux `send-keys` doesn't handle newlines properly - each line after the first gets passed as arguments to the previous command.
