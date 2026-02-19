---
name: manual-testing
description: Manual testing guide for Yato. Use when you need to manually test Yato workflows.
allowed-tools: Bash, Read, Skill
user-invocable: true
argument-hint: "[what to test]"
---

# Manual Test

Guide for manually testing Yato workflows via tmux.

## MANDATORY: Use Real Workflows

You MUST use Yato skills to start a real workflow. DO NOT bypass by running scripts directly (e.g., init-workflow.sh, agent_manager.py, save_team_structure). The point of manual testing is to verify the full end-to-end flow with live Claude agents.

## Step 1: Start a Real Workflow

Use one of these Yato skills:

```
/yato:yato-new-project test-app a simple counter app
/yato:yato-existing-project Add dark mode
/yato:yato-resume
```

This will create a tmux session with a PM and agents. You MUST use these skills — not raw shell commands.

## Step 2: Monitor the Tmux Session

```bash
# List sessions
tmux list-sessions

# List windows in a session
tmux list-windows -t <session>

# Capture pane output (PM is window 0, agents are window 1+)
tmux capture-pane -t <session>:0 -p | tail -50
tmux capture-pane -t <session>:1 -p | tail -50
```

## Step 3: Verify Workflow Files

Check `.workflow/<name>/` in the project directory:

- `status.yml` - workflow status and config
- `prd.md` - generated requirements
- `team.yml` - proposed team structure
- `tasks.json` - task list with status and assignments
- `agents.yml` - registered agents with window numbers
- `agents/<name>/instructions.md` - agent instructions (positive guidance)
- `agents/<name>/constraints.md` - agent constraints (prohibitions)
- `agents/<name>/CLAUDE.md` - agent entry point config
- `agents/<name>/identity.yml` - agent metadata

## Step 4: Observe Agent Behavior

Watch the live agents to verify they:
- Follow their instructions.md (role, responsibilities, communication)
- Respect their constraints.md (system constraints, project constraints)
- Communicate through PM (not directly with user)
- Use /notify-pm for status updates

## Step 5: Cleanup

```bash
# Kill the tmux session when done
tmux kill-session -t <session>
```
