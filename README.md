![Yato Hero](/Orchestrator.png)

# Yato (Yet Another Tmux Orchestrator)

**Run AI agent teams 24/7 while you sleep.** Yato is a Claude Code plugin that deploys autonomous agent teams (PM, Developer, QA) across tmux sessions, enabling parallel work with independent context windows.

## Installation

### From Marketplace (Recommended)

In Claude Code, run:

```
/plugin marketplace add marcospmail/Tmux-Orchestrator
/plugin install yato@Tmux-Orchestrator
```

Once installed, Yato skills are available with the `/yato:` prefix.

### For Development

```bash
# Clone the repository
git clone https://github.com/marcospmail/Tmux-Orchestrator ~/dev/tools/yato

# Load as local plugin for testing
claude --plugin-dir ~/dev/tools/yato
```

### Requirements

- **tmux** - Terminal multiplexer
- **Python 3** - With PyYAML and Jinja2 (`uv` handles dependencies)
- **Claude Code** - v1.0.33+

## Quick Start

### Start a New Project

```
/yato:yato-new-project my-app a todo list with authentication
```

Creates `~/dev/my-app/`, deploys a PM agent, and gives you a tmux attach command.

### Work on an Existing Project

```bash
cd ~/projects/my-existing-app
claude
```

```
/yato:yato-existing-project Add user authentication with OAuth
```

The PM receives your request, analyzes the codebase, proposes a team, and coordinates the work.

### Resume Previous Work

```
/yato:yato-resume
```

Reconnects to your tmux session and continues where you left off.

## How It Works

### Architecture

Yato uses a three-tier hierarchy to overcome context window limitations:

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

Each agent runs in its own tmux window with:
- **Independent context** - No shared token limits
- **Dedicated working directory** - Full project access
- **Two-way communication** - Agents notify PM of progress/blockers

### Workflow

1. **You describe what to build** → `/yato:yato-existing-project Add feature X`
2. **PM proposes a team** → "I recommend 1 developer and 1 QA"
3. **You approve** → PM creates agents and assigns tasks
4. **Agents work in parallel** → Each in their own tmux window
5. **PM coordinates** → Handles blockers, reviews work, merges code
6. **Check-ins keep you informed** → Scheduled status updates

### Agent Communication

**PM → Agents**: Direct messages via tmux
**Agents → PM**: Notifications with status types:
- `DONE` - Task completed
- `BLOCKED` - Waiting for something
- `HELP` - Need guidance
- `PROGRESS` - Milestone update

## Available Skills

| Skill | Description |
|-------|-------------|
| `/yato:yato-new-project` | Start a new project from scratch |
| `/yato:yato-existing-project` | Work on an existing codebase |
| `/yato:yato-resume` | Resume a previous workflow |
| `/yato:cancel-checkin` | Stop scheduled check-ins |
| `/yato:parse-prd-to-tasks` | Convert PRD to task list |

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
        ├── developer/
        └── qa/
```

## CLI Commands

For advanced usage, Yato provides a Python CLI:

```bash
cd ~/dev/tools/yato

# Deploy a PM to a project
uv run yato deploy-pm my-session -p ~/projects/my-app

# Send message to an agent
uv run yato send my-session:1 "What's your progress?"

# Check system status
uv run yato status

# Manage check-ins
uv run yato checkin schedule 15 --note "Progress check"
uv run yato checkin cancel
```

## Agent Types

| Agent | Role | Capabilities |
|-------|------|--------------|
| **PM** | Coordinator | Assigns tasks, reviews work, enforces quality |
| **Developer** | Implementation | Writes code, fixes bugs, creates features |
| **QA** | Testing | Writes tests, verifies functionality |
| **Code-Reviewer** | Review | Reviews PRs, checks security |

## Tips

- **Start small** - Begin with 1 developer, add more as needed
- **Be specific** - Clear requirements = better results
- **Use check-ins** - Schedule regular status updates
- **Trust the PM** - Let it coordinate; intervene only when needed

## License

MIT
