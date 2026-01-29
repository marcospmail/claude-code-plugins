![Orchestrator Hero](/Orchestrator.png)

# Tmux Orchestrator

**Run AI agents 24/7 while you sleep** - The Tmux Orchestrator is a Claude Code plugin that enables Claude agents to work autonomously, schedule their own check-ins, and coordinate across multiple projects without human intervention.

## 📦 Installation

### As a Claude Code Plugin
```bash
# Clone the repository
git clone https://github.com/personal/tmux-orchestrator ~/dev/tools/tmux-orchestrator

# The plugin is automatically detected by Claude Code
```

### Requirements
- **tmux** - Terminal multiplexer
- **Python 3** - For orchestration scripts
- **Claude Code** - CLI tool (v1.0.0+)
- **gh** (optional) - GitHub CLI for project integration

## 🤖 Key Capabilities & Autonomous Features

- **Self-trigger** - Agents schedule their own check-ins and continue work autonomously
- **Two-way communication** - Subagents can notify their PM using `notify-pm.sh`
- **Coordinate** - Project managers assign tasks to engineers across multiple codebases
- **Persist** - Work continues even when you close your laptop
- **Scale** - Run multiple teams working on different projects simultaneously
- **Registry** - Track all active agents and their relationships

## 🏗️ Architecture

The Tmux Orchestrator uses a three-tier hierarchy to overcome context window limitations:

```
┌─────────────┐
│ Orchestrator│ ← You interact here
└──────┬──────┘
       │ Monitors & coordinates
       ▼
┌─────────────┐     ┌─────────────┐
│  Project    │     │  Project    │
│  Manager 1  │ ←─→ │  Manager 2  │ ← Assign tasks, enforce specs
└──────┬──────┘     └──────┬──────┘
       │  ↑                │  ↑
       ▼  │ notify-pm      ▼  │ notify-pm
┌─────────────┐     ┌─────────────┐
│ Engineer 1  │     │ Engineer 2  │ ← Write code, fix bugs, notify PM
└─────────────┘     └─────────────┘
```

### Two-Way Communication
Unlike simple polling, agents can now proactively notify their PM:
- **DONE**: Task completed
- **BLOCKED**: Waiting for input/resources
- **HELP**: Need guidance
- **STATUS**: Progress update
- **PROGRESS**: Milestone reached

## 📁 Project Structure

```
tmux-orchestrator/
├── .claude-plugin/               # Claude Code plugin manifest
│   └── plugin.json               # Plugin metadata
├── agents/                       # Agent definition files
│   ├── pm.md                     # Project Manager agent
│   ├── developer.md              # Developer agent
│   └── qa.md                     # QA Engineer agent
├── commands/                     # Slash commands for Claude
│   ├── orc-init.md               # /orc-init - Initialize project
│   ├── orc-deploy.md             # /orc-deploy - Deploy team
│   ├── orc-status.md             # /orc-status - System status
│   ├── orc-send.md               # /orc-send - Send message
│   ├── orc-read.md               # /orc-read - Read agent output
│   ├── orc-team.md               # /orc-team - Show PM's team
│   ├── orc-plan.md               # /orc-plan - Create execution plan
│   └── parse-prd-to-tasks.md     # /parse-prd-to-tasks - PRD → tasks.json
├── bin/                          # Shell scripts
│   ├── send-message.sh           # Send messages to agents
│   ├── notify-pm.sh              # Subagent → PM notification
│   ├── schedule-checkin.sh       # Schedule future check-ins
│   ├── cancel-checkin.sh         # Cancel pending check-ins
│   ├── checkin-display.sh        # Display check-in status
│   ├── create-agent.sh           # Create and register agents
│   ├── create-team.sh            # Create full team at once
│   ├── init-workflow.sh          # Initialize workflow structure
│   └── resume-workflow.sh        # Resume existing workflow
├── lib/                          # Python modules
│   ├── session_registry.py       # Agent tracking
│   ├── claude_control.py         # CLI interface
│   ├── tmux_utils.py             # Tmux utilities
│   └── orchestrator.py           # Main orchestrator logic
├── templates/                    # Agent briefing templates
│   ├── pm-briefing.md            # PM instructions
│   └── engineer-briefing.md      # Engineer instructions
├── config/
│   └── defaults.conf             # Default configuration
├── .tmux-orchestrator/           # Local state (gitignored)
│   ├── registry.json             # Active agents
│   ├── checkins.json             # Scheduled check-ins
│   └── logs/                     # Agent logs
├── CLAUDE.md                     # Agent behavior instructions
└── README.md                     # This file
```

## 🎯 Quick Start

### Option 1: Using the CLI

```bash
# Initialize a project session with PM and developer
python3 lib/orchestrator.py init my-project -p ~/projects/myapp

# Or use claude_control.py for more control
python3 lib/claude_control.py create my-project pm -p ~/projects/myapp
python3 lib/claude_control.py create my-project developer -p ~/projects/myapp --pm-window my-project:1

# Check status
python3 lib/claude_control.py status

# Send messages
python3 lib/claude_control.py send my-project:1 "What's your current progress?"
```

### Option 2: Using Shell Scripts

```bash
# 1. Create a tmux session
tmux new-session -d -s my-project -c ~/projects/myapp

# 2. Create a PM agent
./bin/create-agent.sh my-project pm -p ~/projects/myapp

# 3. Create a developer agent reporting to PM
./bin/create-agent.sh my-project developer -p ~/projects/myapp --pm-window my-project:1

# 4. Send messages
./bin/send-message.sh my-project:1 "Start implementing the login feature"
```

### Option 3: Full Orchestrator Setup

```bash
# Start orchestrator session
tmux new-session -s orchestrator

# Start Claude
claude

# Brief the orchestrator
"You are the Orchestrator. Use the tools in ~/dev/tools/tmux-orchestrator to:
1. Create a PM for the frontend project
2. Create developers for React and API work
3. Schedule regular check-ins every 30 minutes"
```

## ⚡ Slash Commands

Use these commands directly in Claude Code when working as an orchestrator:

| Command | Description |
|---------|-------------|
| `/orc-init <session> <path>` | Initialize a new project with PM and Developer agents |
| `/orc-deploy <session> <path>` | Deploy a custom team to a session |
| `/orc-status` | Show all registered agents and their status |
| `/orc-send <target> <message>` | Send a message to an agent |
| `/orc-read <target>` | Read recent output from an agent |
| `/orc-team <pm_id>` | Show a PM's team members |
| `/orc-plan` | Create an execution plan for a project |
| `/parse-prd-to-tasks [path]` | Parse a PRD into tasks.json with agent assignments |

### Example: Starting a New Project

```
/orc-init my-app ~/projects/my-app
```

This creates a tmux session with a PM at window :1 and Developer at window :2.

## ⏰ Check-in System

The orchestrator uses a scheduled check-in system to maintain oversight:

### Schedule Check-ins
```bash
./bin/schedule-checkin.sh <minutes> "<note>" [target_window]

# Examples:
./bin/schedule-checkin.sh 15 "Check developer progress"
./bin/schedule-checkin.sh 30 "Full team sync" myproject:1
```

### Display Check-in Status
Run in a dedicated tmux pane to see upcoming and completed check-ins:
```bash
./bin/checkin-display.sh
```

### Cancel Check-ins
When all work is complete:
```bash
./bin/cancel-checkin.sh
```

## 🔧 Core Tools

### bin/send-message.sh
Send messages to any tmux window:
```bash
./bin/send-message.sh session:window "Your message here"
./bin/send-message.sh my-project:0 "Please check the test results"
```

### bin/notify-pm.sh
Subagents notify their PM (run from within an agent's window):
```bash
./bin/notify-pm.sh DONE "Completed login form implementation"
./bin/notify-pm.sh BLOCKED "Waiting for API credentials"
./bin/notify-pm.sh HELP "Need guidance on authentication approach"
./bin/notify-pm.sh STATUS "Working on database schema - 50% complete"
./bin/notify-pm.sh PROGRESS "Finished task 3 of 5"
```

### bin/create-agent.sh
Create and register new agents:
```bash
./bin/create-agent.sh <session> <role> [options]

# Options:
#   -p, --path       Working directory
#   -n, --name       Window name
#   --pm-window      PM this agent reports to
#   --no-start       Don't start Claude automatically
#   --no-brief       Don't send briefing message

# Examples:
./bin/create-agent.sh myproject developer -p ~/code/myapp --pm-window myproject:1
./bin/create-agent.sh myproject qa --pm-window myproject:1
```

### bin/schedule-checkin.sh
Schedule future check-ins:
```bash
./bin/schedule-checkin.sh <minutes> "<note>" [target_window]

# Examples:
./bin/schedule-checkin.sh 30 "Check PM progress on auth system"
./bin/schedule-checkin.sh 60 "Full system status review" tmux-orc:0
```

### lib/claude_control.py
Full CLI for agent management:
```bash
python3 lib/claude_control.py status          # Show all registered agents
python3 lib/claude_control.py list -v         # List all tmux sessions/windows
python3 lib/claude_control.py send <target> <msg>  # Send message
python3 lib/claude_control.py read <target>   # Capture agent output
python3 lib/claude_control.py create <session> <role>  # Create agent
python3 lib/claude_control.py team <pm_id>    # Show PM's team
```

### lib/orchestrator.py
High-level orchestration:
```bash
python3 lib/orchestrator.py init <session> -p <path>  # Create project session
python3 lib/orchestrator.py status            # System status
python3 lib/orchestrator.py status -s         # Monitoring snapshot
python3 lib/orchestrator.py deploy <session> -c team.json  # Deploy team
python3 lib/orchestrator.py start             # Start Claude in all agents
python3 lib/orchestrator.py brief <target> <msg>  # Brief agent
python3 lib/orchestrator.py check <agent>     # Check agent output
```

## 📝 Workflow System

The orchestrator uses a structured workflow system for managing project requirements and tasks.

### Workflow Directory Structure
```
project/
└── .workflow/
    ├── current                   # Name of active workflow
    └── 001-feature-name/
        ├── status.yml            # Workflow status (includes initial_request)
        ├── prd.md                # Product Requirements Document
        ├── tasks.json            # Generated task list (JSON format)
        └── agents/               # Agent configurations
```

**status.yml example:**
```yaml
status: in-progress
title: "Add user authentication"
initial_request: |
  Add OAuth login with Google and GitHub providers
folder: "001-add-user-authentication"
checkin_interval_minutes: 15
session: "myproject"
```

### Initialize a Workflow
```bash
./bin/init-workflow.sh <workflow-name>

# Example:
./bin/init-workflow.sh user-authentication
```

### Resume an Existing Workflow
```bash
./bin/resume-workflow.sh
```

### PRD to Tasks Pipeline

The PM uses `/parse-prd-to-tasks` to break down a PRD into actionable tasks:

1. **Write PRD** → `.workflow/feature-name/prd.md`
2. **Run command** → `/parse-prd-to-tasks`
3. **Tasks generated** → `.workflow/feature-name/tasks.json`

Example tasks.json output:
```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Create LoginForm component",
      "description": "Build React component for login form with email/password fields",
      "activeForm": "Creating LoginForm component",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T3", "T4"]
    },
    {
      "id": "T2",
      "subject": "Implement /api/auth/login endpoint",
      "description": "Create POST endpoint for authentication with JWT",
      "activeForm": "Implementing auth login endpoint",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T3", "T4"]
    },
    {
      "id": "T3",
      "subject": "Test login with valid credentials",
      "description": "Write unit tests for successful login scenarios",
      "activeForm": "Testing login with valid credentials",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1", "T2"],
      "blocks": []
    }
  ],
  "metadata": {
    "created": "2026-01-27T10:00:00Z",
    "updated": "2026-01-27T10:00:00Z",
    "prd": "prd.md"
  }
}
```

## 📋 Best Practices

### Writing Effective Specifications

```markdown
PROJECT: E-commerce Checkout
GOAL: Implement multi-step checkout process

CONSTRAINTS:
- Use existing cart state management
- Follow current design system
- Maximum 3 API endpoints
- Commit after each step completion

DELIVERABLES:
1. Shipping address form with validation
2. Payment method selection (Stripe integration)
3. Order review and confirmation page
4. Success/failure handling

SUCCESS CRITERIA:
- All forms validate properly
- Payment processes without errors
- Order data persists to database
- Emails send on completion
```

### Git Safety Rules

1. **Before Starting Any Task**
   ```bash
   git checkout -b feature/[task-name]
   git status  # Ensure clean state
   ```

2. **Every 30 Minutes**
   ```bash
   git add -A
   git commit -m "Progress: [what was accomplished]"
   ```

3. **When Task Completes**
   ```bash
   git tag stable-[feature]-[date]
   git checkout main
   git merge feature/[task-name]
   ```

### Agent Communication Protocol

**PM to Engineers:**
```bash
./bin/send-message.sh project:2 "STATUS UPDATE: Please provide current progress"
```

**Engineers to PM (from within engineer window):**
```bash
./bin/notify-pm.sh STATUS "Working on login form - 70% complete"
./bin/notify-pm.sh BLOCKED "Need API documentation for /auth endpoint"
./bin/notify-pm.sh DONE "Login form complete with tests"
```

## 🚨 Common Pitfalls & Solutions

| Pitfall | Consequence | Solution |
|---------|-------------|----------|
| Vague instructions | Agent drift, wasted compute | Write clear, specific specs |
| No git commits | Lost work, frustrated devs | Enforce 30-minute commit rule |
| Too many tasks | Context overload, confusion | One task per agent at a time |
| No specifications | Unpredictable results | Always start with written spec |
| Missing checkpoints | Agents stop working | Schedule regular check-ins |
| One-way communication | PM unaware of blockers | Use notify-pm.sh |

## 🎓 Advanced Usage

### Team Configuration File
Create a `team.json` for consistent deployments:
```json
[
  {"role": "pm"},
  {"role": "developer", "name": "Frontend-Dev"},
  {"role": "developer", "name": "Backend-Dev"},
  {"role": "qa"}
]
```

Then deploy:
```bash
python3 lib/orchestrator.py deploy myproject -p ~/code/app -c team.json
```

### Multi-Project Orchestration
```bash
# Create orchestrator session
tmux new-session -s orchestrator

# Initialize multiple projects
python3 lib/orchestrator.py init frontend -p ~/code/frontend
python3 lib/orchestrator.py init backend -p ~/code/backend
python3 lib/orchestrator.py init mobile -p ~/code/mobile

# The orchestrator coordinates between all projects
```

### Python API Usage
```python
from lib.orchestrator import Orchestrator

orc = Orchestrator()

# Create a project session
result = orc.create_project_session("myapp", "/path/to/project")

# Deploy a custom team
team = [
    {"role": "pm"},
    {"role": "developer", "name": "API-Dev"},
    {"role": "qa"}
]
orc.deploy_team("myapp", "/path/to/project", team)

# Get system status
snapshot = orc.create_snapshot()
print(snapshot)
```

## 👥 Agent Types

| Agent | Role | Can Modify Code | Typical Tasks |
|-------|------|-----------------|---------------|
| **pm** | Project Manager | NO | Coordinate team, verify quality, track progress |
| **developer** | Implementation | YES | Write code, implement features, fix bugs |
| **qa** | Testing | NO | Write tests, verify functionality, report issues |
| **code-reviewer** | Review | NO | Review code, check security, approve changes |

### Agent Definition Files

Agent behaviors are defined in `agents/*.md`:

```markdown
---
name: Project Manager
description: Quality-focused team coordinator
tools:
  - Bash
  - Read
  - Glob
  - Grep
---

# Project Manager Agent

You are a Project Manager...
```

## 📚 Core Files Reference

| File | Purpose |
|------|---------|
| **Shell Scripts** | |
| `bin/send-message.sh` | Send messages to agents |
| `bin/notify-pm.sh` | Subagent → PM notifications |
| `bin/create-agent.sh` | Create and register agents |
| `bin/create-team.sh` | Create full team at once |
| `bin/schedule-checkin.sh` | Schedule future check-ins |
| `bin/cancel-checkin.sh` | Cancel pending check-ins |
| `bin/checkin-display.sh` | Display check-in status |
| `bin/init-workflow.sh` | Initialize workflow structure |
| `bin/resume-workflow.sh` | Resume existing workflow |
| **Python Modules** | |
| `lib/session_registry.py` | Agent registry management |
| `lib/claude_control.py` | CLI for agent control |
| `lib/tmux_utils.py` | Tmux interaction utilities |
| `lib/orchestrator.py` | Main orchestrator logic |
| **Commands** | |
| `commands/orc-init.md` | Initialize project session |
| `commands/orc-deploy.md` | Deploy team to session |
| `commands/orc-status.md` | Show system status |
| `commands/parse-prd-to-tasks.md` | PRD to tasks conversion |
| **Other** | |
| `templates/pm-briefing.md` | PM instructions template |
| `templates/engineer-briefing.md` | Engineer instructions template |
| `CLAUDE.md` | Agent behavior instructions |

## 🤝 Contributing

The orchestrator evolves through community discoveries and optimizations. When contributing:

1. Document new tmux commands and patterns in CLAUDE.md
2. Share novel use cases and agent coordination strategies
3. Submit optimizations for agent synchronization
4. Keep command reference up-to-date with latest findings
5. Test improvements across multiple sessions and scenarios

## 📄 License

MIT License - Use freely but wisely. Remember: with great automation comes great responsibility.

---

*"The tools we build today will program themselves tomorrow"* - Alan Kay, 1971
