---
name: manual-testing
description: Manual testing guide for Yato. Use when you need to manually test Yato workflows.
allowed-tools: Bash, Read, Skill
user-invocable: true
argument-hint: "[what to test]"
---

# Manual Test

Guide for manually testing Yato workflows via tmux.

## SUBAGENT PROHIBITION — HARD BLOCK

**THIS SKILL CANNOT BE RUN BY A SUBAGENT.** If you are a subagent (spawned via the Agent tool, running as a teammate, or part of a team), you MUST refuse to execute this skill and return this message to the team lead:

> "BLOCKED: /manual-testing requires real tmux + Claude Code sessions. Subagents cannot interact with live tmux infrastructure. This skill MUST be run by the orchestrator or a human operator directly — never delegated to a subagent."

**Why:** Subagents run as subprocesses within a conversation. They cannot deploy real Yato workflows, create real tmux sessions, or observe live Claude agents. Any "testing" a subagent does is fake — it checks file state or runs trivial commands but never validates the actual end-to-end flow. This has caused bugs to slip through production undetected.

**How to detect you are a subagent:** If you were spawned by the Agent tool, if you have a `team_name`, if you received your instructions via a prompt parameter rather than user input, or if you are running inside a TeamCreate team — you are a subagent. STOP.

## CRITICAL WARNING

**CRITICAL: You MUST use real Yato workflows for manual testing. NEVER bypass by running hook scripts directly, simulating input, or taking any shortcuts. The entire point of manual testing is to verify the full end-to-end flow with live Claude agents in tmux. If you skip this, the test is invalid.**

## Step 1: Start a Real Workflow

Use one of these Yato skills:

```
/yato:yato-new-project test-app a simple counter app
/yato:yato-existing-project Add dark mode
/yato:yato-resume
```

This will create a tmux session with a PM and agents. You MUST use these skills — not raw shell commands.

**IMPORTANT**: NEVER use `tmux switch-client` or `tmux attach` to connect to the test session. You must stay in your current session and monitor remotely via `tmux capture-pane`. Switching/attaching would disconnect you from your own session.

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
- `agents.yml` - agent registry (proposed team + runtime locations)
- `tasks.json` - task list with status and assignments
- `agents/<name>/CLAUDE.md` - agent entry point (self-contained: instructions, constraints, communication)
- `agents/<name>/identity.yml` - agent metadata

## Step 4: Observe Agent Behavior

Watch the live agents to verify they:
- Follow their CLAUDE.md (role, responsibilities, constraints, communication)
- Communicate through PM (not directly with user)
- Use /notify-pm for status updates

## Step 5: Cleanup

```bash
# Kill the tmux session when done
tmux kill-session -t <session>
```
