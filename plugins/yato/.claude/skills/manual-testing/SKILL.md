---
name: manual-testing
description: Manual testing for Yato workflows. Starts Claude Code in a tmux session, runs Yato inside it, and observes live agents working. Use when you need to verify Yato features end-to-end.
allowed-tools: Bash, Read
model: opus
effort: high
user-invocable: true
argument-hint: "[what to test]"
---

# Manual Test — Live End-to-End Workflow Testing

<context>
This skill tests Yato by starting a REAL Claude Code instance in a tmux session, running Yato inside it, and observing the live agents working. You do NOT run any Yato scripts or skills yourself — you start Claude Code and let IT run Yato. You just watch.
</context>

## WHAT "EXECUTING CORRECTLY" MEANS

The test flow is:

1. You create a tmux session
2. You start `claude` (Claude Code) inside that tmux session
3. You type a Yato command (e.g. `/yato-new-project`) into that Claude Code instance
4. You WATCH via `tmux capture-pane` as Claude Code runs Yato, deploys a PM, deploys agents
5. You OBSERVE the agents working, communicating, and completing tasks
6. You VERIFY the specific feature being tested by watching it happen live

**You are a spectator.** You do not run Yato yourself. You do not invoke Yato skills. You do not run Yato scripts. You start Claude Code in tmux and type a Yato command into it. That's it. Then you watch.

### What is NOT valid testing:

- Running Yato scripts directly (init-workflow.sh, orchestrator.py, etc.)
- Invoking Yato skills yourself via the Skill tool
- Reading workflow files and confirming they have correct content
- Deploying the PM but not waiting for agents to start
- Checking templates have the right text
- ANY form of "the files look correct so the feature works"

<instructions>

## Step 1: Create a tmux session and start Claude Code

```bash
# Create a test project directory
PROJECT_NAME="manual-test-$(date +%s)"
PROJECT_PATH="$HOME/dev/$PROJECT_NAME"
mkdir -p "$PROJECT_PATH"

# Use a SEPARATE tmux socket to isolate test sessions from the user's terminal.
# Without this, yato-new-project's switch-client will hijack the user's terminal
# because tmux send-keys associates the caller's client with the test session.
TMUX_SOCKET="yato-test"

# Create a detached session on the isolated socket
SESSION_NAME="manual-test"
tmux -L "$TMUX_SOCKET" new-session -d -s "$SESSION_NAME" -c "$PROJECT_PATH"

# Start Claude Code inside that session
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "claude" Enter
```

**IMPORTANT:** Always use `-L "$TMUX_SOCKET"` for ALL tmux commands in this skill (send-keys, capture-pane, list-windows, list-sessions, kill-session). This keeps the test completely isolated from the user's tmux sessions.

Wait for Claude Code to finish starting up (look for the prompt):
```bash
sleep 10
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -20 | tail -10
```

You should see the Claude Code prompt (the `>` input line). If not, wait longer.

## Step 2: Type the Yato command into Claude Code

Send the appropriate Yato command to the Claude Code instance. Choose the command based on what you're testing:

```bash
# Use whichever Yato command is appropriate for the test:
tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/yato-new-project test-app a simple counter app" Enter
# or: tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/yato-existing-project Add dark mode" Enter
# or: tmux -L "$TMUX_SOCKET" send-keys -t "$SESSION_NAME" "/yato-resume" Enter
# etc.
```

Pick the command that exercises the feature you're testing. For general end-to-end tests, `/yato-new-project` is the simplest. For testing features on existing codebases, use `/yato-existing-project`. For resume flows, use `/yato-resume`.

## Step 3: Wait for the Yato workflow to deploy

Monitor the Claude Code instance to see it deploying the workflow:
```bash
tmux -L "$TMUX_SOCKET" capture-pane -t "$SESSION_NAME" -p -S -50 | tail -30
```

Wait until you see output indicating the PM was deployed and a new session was created. This typically looks like:
- "Project created at: ~/dev/test-app"
- "Session ready!"
- A session name like `test-app_001-...`

Note the **workflow session name** — this is the tmux session where the PM and agents will run (different from your `manual-test` session where Claude Code is running).

## Step 4: Monitor the PM

Once you know the workflow session name, monitor the PM:
```bash
# Check PM output — note: workflow sessions are on the SAME isolated socket
tmux -L "$TMUX_SOCKET" capture-pane -t <workflow-session>:0 -p -S -50 | tail -30
```

Wait for the PM to:
1. Read the initial request
2. Create a PRD
3. Generate tasks (tasks.json)
4. Deploy agents

**DO NOT proceed until you see agent windows deployed:**
```bash
tmux -L "$TMUX_SOCKET" list-windows -t <workflow-session>
```

You must see at least the PM window AND one or more agent windows.

## Step 5: Monitor agents working

```bash
# Check developer output
tmux -L "$TMUX_SOCKET" capture-pane -t <workflow-session>:1 -p -S -50 | tail -30

# Check qa output (if exists)
tmux -L "$TMUX_SOCKET" capture-pane -t <workflow-session>:2 -p -S -50 | tail -30
```

**DO NOT proceed until you see agents actively producing output** (reading files, writing code, running commands).

## Step 6: Observe agent-PM communication

This is the CORE of the test. Watch for:

1. **Agent sends `[DONE]`** — capture the PM pane to see if the PM receives it
2. **PM reacts to `[DONE]`** — does the PM follow the expected flow?
3. **PM sends messages to agents** — does communication work?
4. **tasks.json updates** — read the file to verify status changes

```bash
# Monitor PM for notifications
tmux -L "$TMUX_SOCKET" capture-pane -t <workflow-session>:0 -p -S -100 | grep -i "DONE\|BLOCKED\|notify\|validated\|complete"
```

If testing a specific feature (`$ARGUMENTS`), look for that specific behavior.

## Step 7: Verify the feature being tested

If `$ARGUMENTS` describes what to test, verify that specific behavior by observing it happen live.

If `$ARGUMENTS` is empty, verify the general end-to-end flow: PM creates tasks, agents work, agents communicate back, PM handles notifications.

**How to verify:** Watch the tmux panes. Read the workflow files AFTER you observed the behavior — the files confirm what you already saw, they don't replace seeing it.

```bash
# Read workflow files to confirm observed state
cat <project>/.workflow/<name>/tasks.json | python3 -m json.tool
cat <project>/.workflow/<name>/status.yml
cat <project>/.workflow/<name>/agents/<agent>/agent-tasks.md
```

## Step 8: Report results

Report what you OBSERVED (not what you assume):

```
## Manual Test Results

**Feature tested:** [what was tested]
**Workflow session:** [tmux session name]
**Duration:** [how long you observed]

### What happened:
1. Claude Code ran /yato-new-project and deployed the PM
2. PM created PRD with X tasks
3. Developer started working on T1
4. Developer sent [DONE] to PM
5. PM [validated/did not validate] the work
6. tasks.json shows T1 as [status]

### Pass/Fail:
- [PASS/FAIL] [specific behavior observed or not observed]

### Issues found:
- [any issues]
```

## Step 9: Cleanup

```bash
tmux -L "$TMUX_SOCKET" kill-session -t <workflow-session>
tmux -L "$TMUX_SOCKET" kill-session -t "$SESSION_NAME"
rm -rf "$PROJECT_PATH"
rm -rf <test-app-directory>  # the project created by Yato
```

## Failure Notification (MANDATORY)

If any step, command, API call, or tool in this workflow fails or does not work as expected, you MUST immediately notify the user with:
1. What failed
2. The error or unexpected behavior observed
3. What you plan to do instead (if anything)

Do NOT silently fall back to alternative approaches without informing the user first.

## Self-Update Protocol

If you discovered something new during this task (failures, bugs, edge cases, better approaches, new IDs or mappings), update this SKILL.md file directly without waiting for the user to ask. Skip if the task was routine with no new findings.

</instructions>
