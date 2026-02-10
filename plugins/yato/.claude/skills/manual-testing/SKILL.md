---
name: manual-testing
description: Manual testing guide for Yato. Use when you need to manually test Yato workflows.
allowed-tools: Bash, Read
user-invocable: true
argument-hint: "[what to test]"
---

# Manual Test

Guide for manually testing Yato workflows via tmux.

## Starting a Test

Use Yato skills to start workflows:

```
/yato:yato-new-project test-app a simple counter app
/yato:yato-existing-project Add dark mode
/yato:yato-resume
```

Then attach to the tmux session to monitor.

## Tmux Commands

```bash
# List sessions
tmux list-sessions

# Attach to session (read-only)
tmux attach -t <session> -r

# List windows
tmux list-windows -t <session>

# Capture pane output
tmux capture-pane -t <session>:<window> -p | tail -50

# Kill session when done
tmux kill-session -t <session>
```

## What to Check

**Workflow files** in `.workflow/<name>/`:

- `status.yml` - workflow status
- `prd.md` - requirements
- `team.yml` - proposed agents
- `tasks.json` - task list and status
- `agents.yml` - created agents

**Tmux windows**:

- Window 0: PM agent
- Window 1+: Developer/QA agents

## Quick Monitoring

```bash
# Watch PM
tmux capture-pane -t <session>:0 -p | tail -30

# Watch developer
tmux capture-pane -t <session>:1 -p | tail -30

# Check task status
cat .workflow/*/tasks.json | grep '"status"'
```
