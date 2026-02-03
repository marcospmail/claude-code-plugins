![Yato Hero](/Orchestrator.png)

# Yato (Yet Another Tmux Orchestrator)

**Run AI agent teams 24/7 while you sleep.** Yato is a Claude Code plugin that deploys autonomous agent teams (PM, Developer, QA) across tmux sessions, enabling parallel work with independent context windows.

## Installation

In Claude Code, run:

```
/plugin marketplace add marcospmail/Tmux-Orchestrator
/plugin install yato@Tmux-Orchestrator
```

### Requirements

- **tmux** - Terminal multiplexer
- **Python 3** - With PyYAML and Jinja2 (`uv` handles dependencies)
- **Claude Code** - v1.0.33+

## Usage

### New Project

```
/yato:yato-new-project my-app a todo list with authentication
```

Creates `~/dev/my-app/`, deploys a PM, and gives you a tmux attach command. The PM takes over from there.

### Existing Project

```
/yato:yato-existing-project Add user authentication with OAuth
```

Run this from your project directory. The PM analyzes the codebase, proposes a team, and coordinates the work.

### Resume

```
/yato:yato-resume
```

Reconnects to your tmux session and continues where you left off.

### Cancel Check-ins

```
/yato:cancel-checkin
```

Stops scheduled check-ins when work is complete.

### Loops

```
/yato:loop check the logs --times 3
/yato:loop run tests --every 5m --for 1h
```

Repeat any prompt at intervals.

## How It Works

```
┌─────────────┐
│ Orchestrator│ ← You interact here (Claude Code)
└──────┬──────┘
       │ Deploys & monitors
       ▼
┌─────────────┐
│   Project   │ ← Coordinates team, enforces quality
│   Manager   │
└──────┬──────┘
       │ Assigns tasks
       ▼
┌─────────────────────────────┐
│  Developer  │  QA  │  ...  │ ← Execute tasks, notify PM
└─────────────────────────────┘
```

Each agent runs in its own tmux window with independent context. Agents notify the PM when tasks are done or when they're blocked.

**Workflow:**
1. You describe what to build
2. PM proposes a team
3. You approve → PM creates agents and assigns tasks
4. Agents work in parallel
5. PM coordinates, reviews, and merges

## Workflow Files

Each workflow creates a `.workflow/` directory in your project:

```
project/.workflow/
├── current                     # Active workflow name
└── 001-add-auth/
    ├── status.yml              # Workflow status and settings
    ├── prd.md                  # Requirements document
    ├── team.yml                # Proposed team structure
    ├── tasks.json              # Task assignments
    └── agents/                 # Agent configurations
```

## Agent Types

| Agent | Role |
|-------|------|
| **PM** | Coordinates team, assigns tasks, reviews work |
| **Developer** | Writes code, implements features, fixes bugs |
| **QA** | Writes tests, verifies functionality |
| **Code-Reviewer** | Reviews PRs, checks security |

## License

MIT
