# Agent Skills Visibility & Self-Contained CLAUDE.md

**Date:** 2026-04-02
**Status:** Approved

## Problem

1. The PM has no visibility into what each agent's capabilities or mandatory skills are when creating tasks. The roster hook only shows agent names, not descriptions.
2. Agents must read multiple files (instructions.md, constraints.md) at startup — unnecessary indirection since CLAUDE.md is auto-loaded by Claude Code.

## Solution

### 1. Enrich Agent Descriptions with Mandatory Skills

Update `description` in each agent YAML (`agents/*.yml`) to include mandatory skills/commands. The pattern is: `"[Role summary]. Must run [skill/command] on every task. [Details]"`

Updated descriptions:

| Agent | Description |
|-------|-------------|
| developer | "Implementation and development agent that writes production code" (unchanged) |
| qa | "Quality assurance agent that writes and runs tests (test files only, no production code)" (unchanged) |
| code-reviewer | "Code review agent. Must run `/code-review` skill on every task. Reviews code quality, best practices, and security (read-only)" |
| security-reviewer | "Security analysis agent. Must run `/security-review` skill on every task. Reviews code for vulnerabilities and OWASP concerns (read-only)" |
| designer | "Design and UX agent that creates designs, provides UX recommendations, and ensures design consistency (read-only)" (unchanged) |
| devops | "Infrastructure and deployment agent that manages CI/CD, environments, and system health" (unchanged) |
| code-cleanness-verifier | "Code cleanness verification agent that checks for dead code, unused imports, formatting, and overall code hygiene (read-only)" (unchanged) |

Only agents with mandatory skills get updated descriptions. Others remain as-is.

### 2. Surface Descriptions in PM Roster

Update `hooks/scripts/tasks-status-reminder.py` to load agent role definitions and show descriptions.

Current format:
```
TEAM ROSTER: Your team has 3 agents: developer, qa, code-reviewer.
Assign tasks to all applicable agents when creating or updating tasks.
```

New format:
```
TEAM ROSTER (3 agents):
- developer: Implementation and development agent that writes production code
- code-reviewer: Code review agent. Must run /code-review skill on every task. Reviews code quality, best practices, and security (read-only)
- qa: Quality assurance agent that writes and runs tests (test files only, no production code)

Assign tasks to all applicable agents. When an agent's description mentions a mandatory skill/command, include it in the task instructions.
```

Implementation:
- The hook reads `agents.yml` to get each agent's `role` field
- For each role, loads `agents/<role>.yml` from the plugin directory to get `description`
- Falls back to agent name if role YAML not found

### 3. Self-Contained Agent CLAUDE.md

Inline instructions and constraints directly into the agent's CLAUDE.md template. Remove `instructions.md` and `constraints.md` as separate files.

#### Files to delete:
- `lib/templates/agent_instructions.md.j2`
- `lib/templates/constraints.example.md.j2`

#### Updated CLAUDE.md template structure:

```markdown
# Agent Configuration

## Identity
- Read [identity.yml](./identity.yml) for your role, pane_id, model, and capabilities

## Instructions

[Inlined content from instructions field — role description, responsibilities, communication rules]

## Constraints

[Inlined content from constraints — forbidden actions, off-limits areas, process constraints]

## Tasks
- Read [agent-tasks.md](./agent-tasks.md) for your current tasks
- Monitor this file continuously - PM adds tasks here

## Important Notes
- Re-read agent-tasks.md frequently as PM updates it
- If you encounter any issues, notify your PM immediately
```

#### Agent's external reads shrink to 2 files:

| File | Reason |
|------|--------|
| `identity.yml` | Structured YAML data (pane_id, model, role, can_modify_code) |
| `agent-tasks.md` | Updated frequently by PM during workflow |

#### Changes to agent_manager.py:
- Remove generation of `instructions.md`
- Remove generation of `constraints.md`
- Pass instructions content and constraints content as template variables to `agent_claude.md.j2`
- Update `init_agent_files()` to reflect fewer files

## Files Changed

| File | Action | Description |
|------|--------|-------------|
| `agents/code-reviewer.yml` | Modify | Enrich description with mandatory skill |
| `agents/security-reviewer.yml` | Modify | Enrich description with mandatory skill |
| `hooks/scripts/tasks-status-reminder.py` | Modify | Load and display agent descriptions in roster |
| `lib/templates/agent_claude.md.j2` | Modify | Expand to include instructions + constraints inline |
| `lib/templates/agent_instructions.md.j2` | Delete | No longer needed |
| `lib/templates/constraints.example.md.j2` | Delete | No longer needed |
| `lib/agent_manager.py` | Modify | Stop generating instructions.md/constraints.md, pass content to CLAUDE.md template |
| `tests/unit/` | Modify | Update tests for agent_manager and hook changes |

## What Does NOT Change

- `agents.yml` schema (workflow state)
- `tasks.json` schema
- `status.yml` schema
- `identity.yml` template
- `agent-tasks.md` template
- Agent communication (send-to-agent, notify-pm)
- Check-in system
- No new fields or schema changes
