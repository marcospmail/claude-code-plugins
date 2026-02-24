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
| `bin/` | Shell scripts for agent creation, workflow init, messaging |
| `skills/` | Claude Code skills for orchestration |
| `hooks/` | Event hooks (file access guard, task reminders, checkin control) |
| `config/` | Default configuration (`defaults.conf`) |
| `templates/` | Message templates (engineer-briefing, planning-questions) |
| `agents/` | Agent role definitions (pm.md) |
| `.workflow/` | Per-workflow state (status.yml, tasks.json, agents.yml) |

### Python Module Hierarchy

```
lib/
├── __init__.py           # Package exports
├── orchestrator.py       # High-level API: init, deploy, status
├── claude_control.py     # CLI interface: status, list, send, read, team
├── config.py             # Config loader for defaults.conf
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

1. **Skills** (`skills/*/SKILL.md`) invoke Python modules directly
2. **Modules** (each with `__main__` CLI) handle tmux operations, file management, scheduling
3. **Bin scripts** (`bin/*.sh`) provide shell-level entry points for agent creation and messaging
4. **Workflow state** (`.workflow/<name>/`) tracks agents, tasks, check-ins

## Running Commands

All commands run via `uv` from the yato directory:

```bash
cd ${CLAUDE_PLUGIN_ROOT}

# Send message to agent (by pane ID or session:window)
uv run python lib/tmux_utils.py send %5 "message"
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
    ├── tasks.json             # Generated tasks (JSON format, assigned to agents.yml agents)
    ├── agents.yml             # Agent registry (proposed team + runtime locations)
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
agent_message_suffix: ""              # Workflow-level: PM → agent messages (read fresh each send)
checkin_message_suffix: ""             # Workflow-level: check-in daemon → PM messages (read fresh each send)
agent_to_pm_message_suffix: ""         # Workflow-level: agent → PM messages via notify_pm (read fresh each send)
user_to_pm_message_suffix: ""          # Workflow-level: user prompt → PM context (read fresh each submit)
```

### Dual-Level Message Suffix System

Suffixes use a **stacking** system: both yato-level (global) and workflow-level suffixes are appended if set. No fallback -- they stack.

**Ordering:** `<original message>` → `<yato-level suffix>` → `<workflow-level suffix>` (separated by blank lines).

**Yato-level** (in `config/defaults.conf`):
- `PM_TO_AGENTS_SUFFIX=""` — appended to PM/orchestrator → agent messages
- `AGENTS_TO_PM_SUFFIX=""` — appended to agent → PM messages (notify_pm)
- `CHECKIN_TO_PM_SUFFIX=""` — appended to check-in daemon → PM messages
- `USER_TO_PM_SUFFIX=""` — injected into PM context when user submits a prompt

**Workflow-level** (in `status.yml`):
- `agent_message_suffix` — PM → agent messages (workflow-specific)
- `checkin_message_suffix` — check-in daemon → PM messages (workflow-specific)
- `agent_to_pm_message_suffix` — agent → PM via notify_pm (workflow-specific)
- `user_to_pm_message_suffix` — user prompt → PM context (workflow-specific)

**Direction mapping:**
| Direction | Yato-level (defaults.conf) | Workflow-level (status.yml) |
|-----------|---------------------------|----------------------------|
| PM → Agent | `PM_TO_AGENTS_SUFFIX` | `agent_message_suffix` |
| Agent → PM | `AGENTS_TO_PM_SUFFIX` | `agent_to_pm_message_suffix` |
| Check-in → PM | `CHECKIN_TO_PM_SUFFIX` | `checkin_message_suffix` |
| User → PM | `USER_TO_PM_SUFFIX` | `user_to_pm_message_suffix` |

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

### PM → Agent
PM uses the `/send-to-agent` skill:
```
/send-to-agent developer "You have new tasks. Read your agent-tasks.md for details."
/send-to-agent qa "Please verify the implementation of T1."
```

Or via CLI:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/send-to-agent.sh <agent-name> "Your message"
```

### Agent → PM
Agents use the `/notify-pm` skill:
```
/notify-pm [DONE] Completed task T1
/notify-pm [BLOCKED] Need database credentials
```

Or via CLI:
```bash
${CLAUDE_PLUGIN_ROOT}/bin/notify-pm.sh "[DONE] Completed task"
```

Notification types: DONE, BLOCKED, HELP, STATUS, PROGRESS

### Orchestrator → Agent (low-level)
```bash
uv run python lib/tmux_utils.py send %5 "Your message"
# Or legacy format:
uv run python lib/tmux_utils.py send session:window "Your message"
```

## Tmux Patterns

### Agent Target Format
- **Preferred**: Global pane ID `%N` (e.g., `%5`, `%12`) - stable across window moves/swaps
- Legacy window-based: `session:window` (e.g., `myproject:1`)
- Legacy pane-based: `session:window.pane` (e.g., `myproject:0.1`)

Agents are identified by their global tmux pane ID (`pane_id` field in agents.yml and identity.yml).
This ID is assigned by tmux at pane creation and remains stable regardless of window reordering.

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

### Shell Scripts
The `bin/` directory contains shell scripts used by skills, templates, and some Python modules.
