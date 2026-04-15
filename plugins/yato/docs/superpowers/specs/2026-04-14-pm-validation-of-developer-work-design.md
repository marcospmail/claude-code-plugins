# PM Validation of Developer Work

**Date:** 2026-04-14
**Status:** Draft

## Problem

When a developer sends `[DONE]` to the PM, the PM immediately marks the task as `completed` in tasks.json without verifying the work was actually done correctly. There is no validation step, no structured report of what was done, and no mechanism to send the developer back if the work is incomplete or incorrect.

## Goals

1. PM validates developer work before marking tasks complete
2. Developers write structured work reports so the PM knows exactly what to inspect
3. Validation is per-task (not blanket) via a `needs_validation` field
4. Failed validation sends the agent back with specific feedback
5. Global toggle in `status.yml` to disable validation when not needed
6. Remove unused `task_manager.py` module (dead code cleanup)

## Non-Goals

- Automated validation (linting, test runs) — this is PM judgment
- Blocking hooks or interceptors — enforcement is via PM instructions
- Changes to QA/code-reviewer flows — their work is trusted by default

## Design

### 1. Task Schema Changes

Every task in `tasks.json` gets two new mandatory fields:

```json
{
  "id": "T1",
  "subject": "Implement retry logic",
  "description": "Add exponential backoff to API client",
  "agent": "developer",
  "status": "pending",
  "needs_validation": true,
  "validated": false,
  "blockedBy": [],
  "blocks": ["T2"]
}
```

**`needs_validation`** (boolean, mandatory): Whether the PM must validate this task before marking it complete.

**`validated`** (boolean, mandatory): Whether the PM has validated the completed work. Independent of `status`.

**Completion rule:**

| `needs_validation` | `validated` | Can mark `completed`? |
|---|---|---|
| `true` | `false` | No — PM must validate first |
| `true` | `true` | Yes |
| `false` | `false` | Yes — no validation needed |

### 2. Setting `needs_validation`

Set by the PM (via `/parse-prd-to-tasks`) when generating tasks, based on judgment for each task.

All tasks start with `validated: false`.

### 3. Global Toggle in status.yml

```yaml
validate_tasks: true
```

When `false`, the PM skips validation entirely regardless of per-task `needs_validation` settings — all `[DONE]` notifications are marked complete directly (current behavior).

Default: `true`.

### 4. Work Report Format in agent-tasks.md

Agents must write a detailed work report under their task checkbox before sending `[DONE]`:

```markdown
[x] T3: Add retry logic to API client
  **Work Report:**
  - Modified: `lib/client.py` — wrapped all API calls with retry decorator
  - Created: `lib/retry.py` — exponential backoff, max 3 retries, 1s base delay
  - Decision: Used decorator pattern instead of inline try/catch for cleaner call sites
```

Required elements:
- **Files modified/created** with path and brief description of change
- **Key decisions** made during implementation and rationale

### 5. PM Validation Flow

When PM receives a `[DONE]` notification:

```
[DONE] received from agent
        |
        v
Check validate_tasks in status.yml
        |
        v
validate_tasks == false?
   |-- YES --> mark task completed directly (current behavior)
   |-- NO  --> continue
        |
        v
Read task from tasks.json
        |
        v
needs_validation == true?
   |-- NO  --> mark task completed directly
   |-- YES --> enter validation flow:
                |
                v
          Read agent's agent-tasks.md (work report)
                |
                v
          Read the specific files mentioned in the report
                |
                v
          Compare against task description in tasks.json
                |
                v
          Work looks correct?
             |-- YES --> set validated: true, status: completed
             |-- NO  --> keep validated: false, status: in_progress
                         send feedback to agent via /send-to-agent
                         (specific issues, what needs fixing)
```

The PM uses judgment to pick the validation strategy:
- Read the modified files directly
- Ask the agent follow-up questions if something is unclear
- Delegate to QA/code-reviewer if the change is complex

### 6. Dead Code Cleanup: Remove task_manager.py

`lib/task_manager.py` is not used by any skill, template, or hook. The PM reads/writes tasks.json directly. Remove:

- `lib/task_manager.py` — the module itself
- `tests/unit/test_task_manager.py` — unit tests
- `tests/e2e/test-task-table-format.sh` — E2E tests referencing it
- `tests/e2e/tests-to-implement.md` — remove the task assignment test item
- `CLAUDE.md` — remove task_manager.py references from module hierarchy, running commands, and key concepts
- `lib/__init__.py` — remove TaskManager import/export if present

## Files to Change

| File | Change |
|---|---|
| `skills/parse-prd-to-tasks/SKILL.md` | Add `needs_validation` and `validated` as mandatory fields with role-based defaults |
| `lib/templates/agent_claude.md.j2` | Add work report format and instructions |
| `lib/templates/agent_tasks.md.j2` | Add work report section template |
| `lib/templates/pm_planning_briefing.md.j2` | Replace Step 13 with validation flow |
| `lib/workflow_ops.py` | Add `validate_tasks: true` to status.yml creation (line ~134) |
| `lib/task_manager.py` | DELETE |
| `tests/unit/test_task_manager.py` | DELETE |
| `tests/e2e/test-task-table-format.sh` | Remove task_manager.py references |
| `tests/e2e/tests-to-implement.md` | Remove task_manager.py test item |
| `CLAUDE.md` | Remove task_manager.py references |
| `lib/__init__.py` | Remove TaskManager import/export |
