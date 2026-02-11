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
                    notify_pm() (reports up)
```

### Key Components

| Directory | Purpose |
|-----------|---------|
| `lib/` | Python modules - core orchestration logic |
| `lib/templates/` | Jinja2 templates for agent files |
| `skills/` | Claude Code skills for orchestration |
| `agents/` | Agent role definitions (pm.md, developer.md, qa.md) |
| `.workflow/` | Per-workflow state (status.yml, tasks.json, agents.yml) |

### Python Module Hierarchy

```
lib/
├── __init__.py           # Package exports
├── cli.py                # Unified CLI entry point (yato command)
├── orchestrator.py       # High-level API: init, deploy, status
├── claude_control.py     # CLI interface: status, list, send, read, team
├── session_registry.py   # Agent class definition
├── workflow_registry.py  # Workflow-scoped agent management
├── tmux_utils.py         # Tmux operations + send_message, notify_pm
├── workflow_ops.py       # Workflow folder/slug utilities
├── checkin_scheduler.py  # Check-in scheduling and management
├── task_manager.py       # Task assignment and display
├── agent_manager.py      # Agent creation and file generation
└── templates/            # Jinja2 templates for agent files
    ├── agent_identity.yml.j2
    ├── agent_instructions.md.j2
    ├── agent_claude.md.j2
    ├── agent_tasks.md.j2
    └── constraints.example.md.j2
```

**Dependency flow**: `orchestrator.py` → `workflow_ops.py` + `agent_manager.py` + `tmux_utils.py`

### Data Flow

1. **Skills** (`skills/*.md`) invoke Python CLI
2. **Python CLI** (`lib/cli.py`) routes to appropriate modules
3. **Modules** handle tmux operations, file management, scheduling
4. **Workflow state** (`.workflow/<name>/`) tracks agents, tasks, check-ins

## Running Commands

All commands run via `uv` from the yato directory:

```bash
cd ${CLAUDE_PLUGIN_ROOT}

# Send message to agent
uv run python lib/tmux_utils.py send <session:window> "message"

# Notify PM
uv run python lib/tmux_utils.py notify "[DONE] Task completed"

# Check-in management (daemon-based)
uv run python lib/checkin_scheduler.py start 15 --note "Progress check" --target "session:0" --workflow "001-name"
uv run python lib/checkin_scheduler.py cancel --workflow "001-name"
uv run python lib/checkin_scheduler.py status --workflow "001-name"

# Task management
uv run python lib/task_manager.py assign developer "Implement feature X"
uv run python lib/task_manager.py table
uv run python lib/task_manager.py list

# Workflow operations
uv run python lib/workflow_ops.py list
uv run python lib/workflow_ops.py current
uv run python lib/workflow_ops.py create "Add feature Y"

# Agent management
uv run python lib/agent_manager.py create myproject developer -p ~/myproject
uv run python lib/agent_manager.py init-files dev developer

# System status
uv run python lib/claude_control.py status
uv run python lib/claude_control.py status --json

# Orchestrator
uv run python lib/orchestrator.py init <session> -p <path>
uv run python lib/orchestrator.py deploy <session> -p <path>
uv run python lib/orchestrator.py status
```

## Key Concepts

### Workflow System
Projects use `.workflow/` directories:
```
project/.workflow/
├── current                    # Active workflow name (symlink or file)
└── 001-feature-name/
    ├── status.yml             # Workflow status (includes initial_request)
    ├── prd.md                 # Requirements
    ├── team.yml               # Proposed team structure (agents to create)
    ├── tasks.json             # Generated tasks (JSON format, assigned to team.yml agents)
    ├── agents.yml             # Runtime agent registry (created agents)
    ├── checkins.json          # Check-in schedule and history
    └── agents/                # Agent configs
        ├── developer/
        │   ├── identity.yml
        │   ├── instructions.md
        │   ├── constraints.example.md
        │   ├── CLAUDE.md
        │   └── agent-tasks.md
        └── qa/
            └── ...
```

**status.yml** contains all workflow metadata:
```yaml
status: in-progress
title: "Add hourly cron"
initial_request: |
  User's original request goes here...
folder: "/path/to/project/.workflow/001-add-hourly-cron"  # Absolute path
checkin_interval_minutes: _  # Placeholder until user selects interval (e.g., 3, 5, 10)
session: "myproject"
agent_message_suffix: ""      # Appended to orchestrator/PM → agent messages (read fresh each send)
checkin_message_suffix: ""     # Appended to check-in daemon → PM messages (read fresh each send)
```

**team.yml** defines the proposed team structure:
```yaml
agents:
  - name: developer
    role: developer
    model: sonnet
  - name: qa
    role: qa
    model: sonnet
```

**tasks.json** assigns tasks to agents:
```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement feature X",
      "description": "Detailed description...",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2"]
    }
  ]
}
```

### Check-in System

The check-in system uses a **single long-running daemon process** that:
1. Runs in background, polling every 10 seconds
2. Sends check-in messages to the PM at configured intervals
3. Auto-stops when all tasks are completed
4. Stores its PID in `checkins.json` for reliable control

**Check-in lifecycle:**
- Started by PM via `/schedule-checkin` or auto-started by `tasks-change-hook.py`
- Daemon sends check-ins at the interval specified in `status.yml`
- Cancelled via `/cancel-checkin` (kills the daemon process)
- Auto-restarts via hook when tasks.json is edited and daemon is dead

**checkins.json structure:**
```json
{
  "checkins": [
    {
      "id": "123456",
      "status": "pending",
      "scheduled_for": "2026-01-23T15:30:00",
      "note": "Check developer progress",
      "target": "myproject:0"
    },
    {
      "id": "123457",
      "status": "done",
      "scheduled_for": "2026-01-23T15:45:00",
      "completed_at": "2026-01-23T15:45:02",
      "note": "Auto check-in",
      "target": "myproject:0"
    }
  ],
  "daemon_pid": 12345
}
```

**Check-in statuses:** `pending`, `done`, `cancelled`, `stopped`, `resumed`

**CLI Commands:**
```bash
# Start check-in daemon
uv run python lib/checkin_scheduler.py start 5 --note "Progress check" --target "session:0" --workflow "001-name"

# Cancel check-in daemon
uv run python lib/checkin_scheduler.py cancel --workflow "001-name"

# Check status
uv run python lib/checkin_scheduler.py status --workflow "001-name"
```

## Agent Communication

### Orchestrator → Agent
```python
from lib import send_message
send_message("session:window", "Your message")
```

Or via CLI:
```bash
uv run python lib/tmux_utils.py send session:window "Your message"
```

### Agent → PM
Agents report up using notification types:
```bash
# From agent's terminal
${CLAUDE_PLUGIN_ROOT}/bin.archive/notify-pm.sh "[DONE] Completed task"
```

Or via Python:
```python
from lib import notify_pm
notify_pm("[DONE] Completed task")
```

Notification types: DONE, BLOCKED, HELP, STATUS, PROGRESS

## Tmux Patterns

### Agent Target Format
- Window-based: `session:window` (e.g., `myproject:1`)
- Pane-based: `session:window.pane` (e.g., `myproject:0.1`)

### Creating Windows with Correct Directory
```bash
# ALWAYS use -c flag to set directory
tmux new-window -t session -n "name" -c "/path/to/project"
```

### Bash Command Chaining (IMPORTANT)

When running multiple bash commands, **always chain them on a single line** using `&&` or `;`. Never use newlines between commands.

**CORRECT:**
```bash
tmux capture-pane -t "$SESSION:1" -p | tail -30 && echo "=== Next ===" && tmux capture-pane -t "$SESSION:2" -p | tail -20
```

**INCORRECT (causes parsing errors):**
```bash
# BAD: Newlines break command parsing
tmux capture-pane -t "$SESSION:1" -p | tail -30
echo "=== Next ==="
```

## Development

### Running Tests
```bash
# E2E tests
bash tests/e2e/run-all-tests.sh
```

### Package Structure
The project uses `pyproject.toml` with uv for dependency management:
- `pyyaml>=6.0` - YAML parsing
- `jinja2>=3.1` - Template rendering

### Archived Bash Scripts
Legacy bash scripts are preserved in `bin.archive/` for reference. See `bin.archive/README.md` for the migration mapping.

Symlinks in `bin/` point to `bin.archive/` for backward compatibility with:
- E2E tests that call `bin/*.sh` scripts
- PM/agent briefings that reference `bin/*.sh` commands
