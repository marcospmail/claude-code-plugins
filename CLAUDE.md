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
cd ~/dev/tools/yato

# Send message to agent
uv run yato send <session:window> "message"

# Notify PM
uv run yato notify "[DONE] Task completed"

# Check-in management
uv run yato checkin schedule 15 --note "Progress check"
uv run yato checkin cancel
uv run yato checkin list

# Task management
uv run yato tasks assign developer "Implement feature X"
uv run yato tasks table
uv run yato tasks list

# Workflow operations
uv run yato workflow list
uv run yato workflow current
uv run yato workflow create "Add feature Y"

# Agent management
uv run yato agent create myproject developer -p ~/myproject
uv run yato agent init-files dev developer

# System status
uv run yato status
uv run yato status --json

# Using orchestrator directly
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
folder: "001-add-hourly-cron"
checkin_interval_minutes: 15
session: "myproject"
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
Scheduled check-ins in `.workflow/<name>/checkins.json`:
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

## Agent Communication

### Orchestrator → Agent
```python
from lib import send_message
send_message("session:window", "Your message")
```

Or via CLI:
```bash
uv run yato send session:window "Your message"
```

### Agent → PM
Agents report up using notification types:
```bash
# From agent's terminal
~/dev/tools/yato/bin.archive/notify-pm.sh "[DONE] Completed task"
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
# E2E tests (comprehensive)
bash tests/e2e/run-all-tests.sh

# Unit tests
uv run pytest tests/
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
