---
name: send-to-agent
description: Send a message to a team agent. Use this to delegate tasks, provide instructions, answer questions, or follow up on work. Only for PM agents.
allowed-tools: Bash
user-invocable: false
disable-model-invocation: false
---

# Send to Agent

Send a message to a team agent via their tmux window.

## Arguments
- agent_name: Name of the agent to message (as listed in agents.yml) (required)
- message: Message to send to the agent (required)

## Before Sending (IMPORTANT)

If you are delegating NEW work or modifying existing tasks, you MUST update task files FIRST:

1. **Update tasks.json** — Add or modify the task entry (single source of truth)
2. **Update the agent's agent-tasks.md** — Reflect the changes from tasks.json
3. **Then send the message** using the command below

If you are answering a question, providing clarification, or following up on existing work, you can send directly.

## Steps

1. **Send the message:**
```bash
${CLAUDE_PLUGIN_ROOT}/bin/send-to-agent.sh <agent_name> "<message>"
```

2. **Check** the output for success or error messages.

## Examples
```
/send-to-agent developer "You have new tasks assigned. Read your agent-tasks.md for T3 details and begin work."
/send-to-agent qa "Please verify the implementation of T1 — check the acceptance criteria in your agent-tasks.md."
/send-to-agent developer "Good question — yes, use PostgreSQL for that migration. Proceed with your current approach."
```
