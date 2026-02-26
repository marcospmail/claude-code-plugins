# Yato (Yet Another Tmux Orchestrator)

**Deploy autonomous Claude agent teams that coordinate, build, and iterate on your codebase in parallel.** Yato is a Claude Code plugin that orchestrates multiple agents (PM, developers, QA, reviewers, etc.) across tmux sessions, each with its own independent context window.

## Installation

In Claude Code, run:

```
/plugin marketplace add marcospmail/claude-code-plugins
/plugin install yato@claude-code-plugins
```

### Requirements

- **tmux** - Terminal multiplexer
- **uv** - Python package manager (handles Python and dependencies automatically)
- **Claude Code**

## Quick Start

### New Project

```
/yato:yato-new-project my-app a todo list with authentication
```

Creates `~/my-app/`, deploys a Project Manager, and gives you a tmux attach command. The PM takes over from there - proposing a team, creating agents, and coordinating the work.

### Existing Project

```
/yato:yato-existing-project Add user authentication with OAuth
```

Run this from your project directory. The PM analyzes your codebase, proposes a team structure, and coordinates the implementation.

### Resume

```
/yato:yato-resume
```

Reconnects to your tmux session and restores all agents where they left off. Use this after closing your terminal or coming back to a project.

### Cleanup

```
/yato:yato-cleanup
```

Tears down a running Yato workflow session. Stops all agents, kills the tmux session, cancels pending check-ins, and optionally deletes the workflow folder. Use when you're done with a workflow and want to free up resources.

## How It Works

```
┌─────────────┐
│     You      │ ← Describe what to build
└──────┬──────┘
       │ Deploys
       ▼
┌─────────────┐
│   Project   │ ← Proposes team, assigns tasks, reviews work
│   Manager   │
└──────┬──────┘
       │ Creates & coordinates
       ▼
┌──────────────────────────────────┐
│ Developer │ QA │ Reviewer │ ...  │ ← Work in parallel, notify PM
└──────────────────────────────────┘
       │
       └──→ PM ← Agents report back via /notify-pm
```

Each agent runs in its own tmux window with an independent Claude context. Agents notify the PM when tasks are done or when they're blocked.

**Workflow:**
1. You describe what to build (or provide a PRD)
2. PM analyzes the codebase and proposes a team
3. You approve the team → PM creates agents and assigns tasks
4. Agents work in parallel across tmux windows
5. PM coordinates, reviews, and handles blockers
6. Check-in daemon periodically prompts PM to verify progress

## Agents

Agents are **dynamic** - the PM proposes a team based on your task, and you approve it. Teams can have any number of agents with custom names.

Yato comes with predefined roles (developer, qa, code-reviewer, devops, etc.) but also supports fully custom roles. A team can have multiple agents of the same role (e.g., two developers working on different parts of the codebase). Each agent gets a unique name like `frontend-dev`, `backend-dev`, or `qa-validator`.

**Example agents.yml** (proposed team, before deployment):
```yaml
pm:
  name: pm
  role: pm
  session: "my-session"
  window: 0
  pane_id: "%1"
  model: opus

agents:
  - name: backend-dev
    role: developer
    pane_id: ""
    model: sonnet
  - name: frontend-dev
    role: developer
    pane_id: ""
    model: sonnet
  - name: qa
    role: qa
    pane_id: ""
    model: sonnet
```

After deployment, each agent's `pane_id` is populated with a global tmux pane ID (e.g., `%5`, `%12`). This ID is stable across window reordering and is the preferred targeting format for all agent communication.

### Agent Communication

**PM to agents** - The PM uses `/send-to-agent` to delegate tasks:
```
/send-to-agent backend-dev "New tasks assigned. Read your agent-tasks.md for T3 details."
```

**Agents to PM** - Agents use `/notify-pm` with a status prefix:
```
/notify-pm [DONE] Completed task T1 - implemented login endpoint
/notify-pm [BLOCKED] Need database credentials to proceed
/notify-pm [HELP] Should I use REST or GraphQL for the new API?
/notify-pm [STATUS] 3 of 5 subtasks complete
/notify-pm [PROGRESS] Working on database migration, 60% done
```

## Check-in System

Check-ins are a background daemon that periodically prompts the PM to review team progress. This prevents the PM from going idle while agents are working.

**How it works:**
1. A daemon process runs in the background, polling at a configured interval
2. At each interval, it sends a message to the PM asking for a status check
3. The PM then reviews agent progress, reassigns tasks if needed, and handles blockers
4. The daemon auto-stops when all tasks in `tasks.json` are completed

**Cancel check-ins manually:**
```
/yato:cancel-checkin
```

## Workflow Files

Each workflow creates a `.workflow/` directory in your project:

```
project/.workflow/
├── current                          # Active workflow name
└── 001-add-auth/
    ├── status.yml                   # Workflow metadata, settings, message suffixes
    ├── prd.md                       # Requirements document
    ├── codebase-analysis.md         # Targeted analysis of relevant code areas
    ├── tasks.json                   # Task assignments with dependencies
    ├── agents.yml                   # Agent registry (proposed team + runtime locations)
    ├── checkins.json                # Check-in schedule, history, and daemon PID
    └── agents/                      # Per-agent configuration
        ├── pm/
        │   ├── identity.yml         # Agent identity (name, role, model)
        │   ├── instructions.md      # Agent-specific instructions
        │   ├── constraints.md       # Behavioral constraints
        │   ├── CLAUDE.md            # Claude Code context for this agent
        │   └── agent-tasks.md       # Tasks assigned to this agent
        ├── backend-dev/
        │   └── ...                  # Same structure
        └── qa/
            └── ...                  # Same structure
```

### Key Files

| File | Purpose |
|------|---------|
| **status.yml** | Workflow status, session name, check-in interval, message suffix configuration |
| **prd.md** | Requirements document - what to build and why |
| **codebase-analysis.md** | Automated analysis of relevant project areas for the task (created by PM when needed) |
| **tasks.json** | All tasks with IDs, descriptions, agent assignments, status, and dependency chains (`blockedBy`/`blocks`) |
| **agents.yml** | Agent registry - proposed team (name, role, model) and runtime locations (session, window) |
| **checkins.json** | Check-in daemon state - schedule history and daemon PID |
| **identity.yml** | Per-agent: name, role, model, project path |
| **instructions.md** | Per-agent: detailed instructions for the agent's work |
| **agent-tasks.md** | Per-agent: the specific tasks assigned to this agent |

## All Skills

| Skill | User-invocable | Description |
|-------|:-:|-----------|
| `/yato:yato-new-project` | Yes | Start a new project from scratch |
| `/yato:yato-existing-project` | Yes | Work on an existing codebase |
| `/yato:yato-resume` | Yes | Resume a workflow from where you left off |
| `/yato:yato-cleanup` | Yes | Tear down a running workflow session |
| `/yato:cancel-checkin` | Yes | Cancel the automatic check-in daemon |
| `send-to-agent` | No (PM only) | Send a message to a team agent |
| `notify-pm` | No (Agents only) | Notify PM with status update |
| `parse-prd-to-tasks` | No (PM only) | Parse PRD into tasks.json with agent assignments |
| `test-workflow` | No | Guide for testing Yato workflow features |

## License

MIT
