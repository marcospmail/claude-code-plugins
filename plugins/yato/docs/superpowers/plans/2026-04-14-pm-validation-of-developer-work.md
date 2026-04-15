# PM Validation of Developer Work — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add a PM validation step so developer tasks are reviewed before being marked complete, with structured work reports and per-task validation flags.

**Architecture:** Template-driven approach — changes to Jinja2 templates (agent instructions, PM briefing) and the parse-prd-to-tasks skill enforce the new flow. One Python change adds `validate_tasks` to status.yml creation. Dead code cleanup removes the unused `task_manager.py` module.

**Tech Stack:** Jinja2 templates, Python (workflow_ops.py), YAML (status.yml), JSON (tasks.json)

---

## File Structure

| File | Action | Responsibility |
|---|---|---|
| `lib/workflow_ops.py` | Modify | Add `validate_tasks: true` to status.yml creation |
| `skills/parse-prd-to-tasks/SKILL.md` | Modify | Add `needs_validation` + `validated` as mandatory task fields |
| `lib/templates/agent_claude.md.j2` | Modify | Add work report instructions for agents |
| `lib/templates/agent_tasks.md.j2` | Modify | Add work report section template |
| `lib/templates/pm_planning_briefing.md.j2` | Modify | Replace Step 13 with validation flow |
| `CLAUDE.md` | Modify | Update tasks.json schema docs, remove task_manager references |
| `lib/__init__.py` | Modify | Remove TaskManager import/export |
| `tests/unit/test_init.py` | Modify | Remove TaskManager import test |
| `tests/unit/test_workflow_ops.py` | Modify | Add test for `validate_tasks` in status.yml |
| `lib/task_manager.py` | DELETE | Unused module |
| `tests/unit/test_task_manager.py` | DELETE | Tests for deleted module |
| `tests/e2e/test-task-table-format.sh` | Modify | Remove tests 8-10 (task_manager.py tests) |
| `tests/e2e/tests-to-implement.md` | Modify | Remove task_manager.py test item |

---

### Task 1: Add `validate_tasks` to status.yml creation

**Files:**
- Modify: `lib/workflow_ops.py:134-146`
- Modify: `tests/unit/test_workflow_ops.py:147-156`

- [ ] **Step 1: Write the failing test**

In `tests/unit/test_workflow_ops.py`, add an assertion to the existing `test_creates_status_yml_with_fields` test (after line 156):

```python
        assert data["validate_tasks"] is True
```

- [ ] **Step 2: Run test to verify it fails**

Run: `cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato && uv run pytest tests/unit/test_workflow_ops.py::TestCreateWorkflowFolder::test_creates_status_yml_with_fields -v`

Expected: FAIL with `KeyError: 'validate_tasks'`

- [ ] **Step 3: Add `validate_tasks` to status.yml creation**

In `lib/workflow_ops.py`, add `validate_tasks` to the `status_data` dict at line 145 (before the closing `}`):

```python
            "user_to_pm_message_suffix": "",
            "validate_tasks": True,
```

- [ ] **Step 4: Run test to verify it passes**

Run: `cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato && uv run pytest tests/unit/test_workflow_ops.py::TestCreateWorkflowFolder::test_creates_status_yml_with_fields -v`

Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/workflow_ops.py tests/unit/test_workflow_ops.py
git commit -m "feat: add validate_tasks toggle to status.yml creation"
```

---

### Task 2: Add `needs_validation` and `validated` to parse-prd-to-tasks skill

**Files:**
- Modify: `skills/parse-prd-to-tasks/SKILL.md:112-153`

- [ ] **Step 1: Update the task JSON schema example**

In `skills/parse-prd-to-tasks/SKILL.md`, replace the JSON example at lines 113-142 with the updated schema that includes the two new fields. Find the existing example block:

```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Brief task title (imperative form)",
      "description": "Detailed description with acceptance criteria",
      "activeForm": "Present continuous form for status display (e.g., 'Implementing user auth')",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2", "T3"]
    },
    {
      "id": "T2",
      "subject": "Write unit tests for user auth",
      "description": "Test login, logout, token refresh endpoints",
      "activeForm": "Writing unit tests for user auth",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1"],
      "blocks": []
    }
  ],
```

Replace with:

```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Brief task title (imperative form)",
      "description": "Detailed description with acceptance criteria",
      "activeForm": "Present continuous form for status display (e.g., 'Implementing user auth')",
      "agent": "developer",
      "status": "pending",
      "needs_validation": true,
      "validated": false,
      "blockedBy": [],
      "blocks": ["T2", "T3"]
    },
    {
      "id": "T2",
      "subject": "Write unit tests for user auth",
      "description": "Test login, logout, token refresh endpoints",
      "activeForm": "Writing unit tests for user auth",
      "agent": "qa",
      "status": "pending",
      "needs_validation": false,
      "validated": false,
      "blockedBy": ["T1"],
      "blocks": []
    }
  ],
```

- [ ] **Step 2: Update the Task Fields documentation**

In the same file, find the task fields list (lines 144-152). After the `status` field entry, add:

```
- `needs_validation`: Boolean (mandatory). Whether PM must validate before marking complete. Default by role: developer=true, qa=false, code-reviewer=false, security-reviewer=false
- `validated`: Boolean (mandatory). Whether PM has validated the work. Always starts as `false`
```

- [ ] **Step 3: Add validation rules to the constraints section**

In the `<constraints>` section (lines 183-194), add before the closing `</constraints>`:

```
- Every task MUST have `needs_validation` (boolean) and `validated: false` fields
- Default `needs_validation` by agent role: developer=true, qa=false, code-reviewer=false, security-reviewer=false
- A task with `needs_validation: true` cannot be marked `completed` until `validated` is set to `true` by the PM
```

- [ ] **Step 4: Add validation rules to the guidelines section**

In the `<guidelines>` section, under the **DO:** list (around line 167), add:

```
- Always set `needs_validation` based on agent role (developer=true, others=false by default)
- Always initialize `validated` to `false` on every task
```

- [ ] **Step 5: Commit**

```bash
git add skills/parse-prd-to-tasks/SKILL.md
git commit -m "feat: add needs_validation and validated fields to task schema"
```

---

### Task 3: Add work report instructions to agent templates

**Files:**
- Modify: `lib/templates/agent_claude.md.j2:20-26`
- Modify: `lib/templates/agent_tasks.md.j2:1-5`

- [ ] **Step 1: Update agent_claude.md.j2 with work report instructions**

In `lib/templates/agent_claude.md.j2`, replace the existing communication examples (lines 22-26):

```
#### How to Communicate:
- **If you need information**: `/notify-pm [BLOCKED] Need database connection details`
- **If you have a question**: `/notify-pm [HELP] Should I apply migration to production?`
- **If you're done**: `/notify-pm [DONE] Completed task X`
- **If you're stuck**: `/notify-pm [BLOCKED] Cannot proceed because Y`
```

With:

```
#### How to Communicate:
- **If you need information**: `/notify-pm [BLOCKED] Need database connection details`
- **If you have a question**: `/notify-pm [HELP] Should I apply migration to production?`
- **If you're done**: `/notify-pm [DONE] Completed task X`
- **If you're stuck**: `/notify-pm [BLOCKED] Cannot proceed because Y`

#### Work Report (MANDATORY before sending [DONE]):

Before sending a `[DONE]` notification, you MUST write a work report in your `agent-tasks.md` under the completed task checkbox. The PM will use this to validate your work.

**Format:**
```markdown
[x] T3: Add retry logic to API client
  **Work Report:**
  - Modified: `lib/client.py` — wrapped all API calls with retry decorator
  - Created: `lib/retry.py` — exponential backoff, max 3 retries, 1s base delay
  - Decision: Used decorator pattern instead of inline try/catch for cleaner call sites
```

**Required elements:**
- **Files modified/created** — full path + brief description of what changed
- **Key decisions** — choices made during implementation and why

Do NOT send `[DONE]` without writing the work report first. The PM will read this report and inspect the files you listed.
```

- [ ] **Step 2: Update agent_tasks.md.j2 with work report section**

Replace the entire content of `lib/templates/agent_tasks.md.j2`:

```
## Tasks
[ ] Task description here
[ ] **Notify PM when done** (run: notify-pm skill "[DONE] from {{ name }}: summary")

## Work Report Format
When completing a task, write your report under the task checkbox BEFORE sending [DONE]:
```
[x] TX: Task subject
  **Work Report:**
  - Modified: `path/to/file.py` — what you changed and why
  - Created: `path/to/new_file.py` — what this file does
  - Decision: What you chose and why
```

## References
```

- [ ] **Step 3: Commit**

```bash
git add lib/templates/agent_claude.md.j2 lib/templates/agent_tasks.md.j2
git commit -m "feat: add mandatory work report format to agent templates"
```

---

### Task 4: Update PM briefing with validation flow

**Files:**
- Modify: `lib/templates/pm_planning_briefing.md.j2:234-248`

- [ ] **Step 1: Replace Step 13 in pm_planning_briefing.md.j2**

Find Step 13 (lines 234-248):

```
### Step 13: Handle Agent Notifications

CRITICAL - When receiving agent notifications (e.g., '[DONE] from dev: ...'), IMMEDIATELY update tasks.json:

a) Read `.workflow/$WORKFLOW_NAME/tasks.json`
b) Find the task(s) mentioned by the agent and update status:
   - '[DONE]' notifications -> set status to 'completed' (work was ACTUALLY performed)
   - '[BLOCKED]' notifications -> set status to 'blocked'
   - '[STATUS]' or '[PROGRESS]' -> may update to 'in_progress' if pending
   NEVER mark a task 'completed' unless work was ACTUALLY DONE.
   Blocked tasks stay 'blocked' until resolved - you cannot skip tasks.
c) Write the updated tasks.json back to the file
d) Acknowledge to the agent that you received their update

EXAMPLE: If you receive '[DONE] from dev: Counter app complete', read tasks.json, find tasks assigned to 'dev', change their status to 'completed', write the file.
```

Replace with:

```
### Step 13: Handle Agent Notifications

When receiving agent notifications, follow this flow:

**For '[BLOCKED]' notifications:** Set task status to 'blocked' in tasks.json.
**For '[STATUS]' or '[PROGRESS]':** May update to 'in_progress' if pending.

**For '[DONE]' notifications — VALIDATION FLOW:**

a) Read `.workflow/$WORKFLOW_NAME/status.yml` — check `validate_tasks` field.
   If `validate_tasks` is `false`, skip validation and mark task completed directly (go to step f).

b) Read `.workflow/$WORKFLOW_NAME/tasks.json` — find the task mentioned by the agent.

c) Check the task's `needs_validation` field:
   - If `needs_validation` is `false` → skip validation, go to step f.
   - If `needs_validation` is `true` → continue to step d.

d) **VALIDATE THE WORK:**
   1. Read the agent's `agent-tasks.md` — find the **Work Report** section under the completed task.
   2. Read the specific files listed in the work report to verify the changes are correct.
   3. Compare the work against the task description and acceptance criteria in tasks.json.
   4. Use your judgment — you may:
      - Read the modified files directly to verify correctness
      - Ask the agent follow-up questions via `/send-to-agent` if something is unclear
      - Delegate deeper review to QA or code-reviewer if the change is complex

e) **VALIDATION DECISION:**
   - **PASS:** Set `validated: true` and `status: completed` in tasks.json. Acknowledge to the agent.
   - **FAIL:** Keep `validated: false` and `status: in_progress`. Send specific feedback to the agent via `/send-to-agent` explaining what needs fixing. The agent will fix and re-send `[DONE]`.

f) Write the updated tasks.json back to the file.
g) Acknowledge to the agent that you received their update.

**COMPLETION RULE:** A task with `needs_validation: true` can ONLY be marked `completed` if `validated` is also `true`.

NEVER mark a task 'completed' unless work was ACTUALLY DONE and validated (if required).
Blocked tasks stay 'blocked' until resolved - you cannot skip tasks.
```

- [ ] **Step 2: Commit**

```bash
git add lib/templates/pm_planning_briefing.md.j2
git commit -m "feat: replace immediate task completion with PM validation flow"
```

---

### Task 5: Update CLAUDE.md documentation

**Files:**
- Modify: `CLAUDE.md:55-100`

- [ ] **Step 1: Remove task_manager.py from module hierarchy**

In `CLAUDE.md`, find line 61:

```
├── task_manager.py       # Task assignment and display
```

Delete this line entirely.

- [ ] **Step 2: Remove task management commands**

Find lines 97-100:

```
# Task management
uv run python lib/task_manager.py assign developer "Implement feature X"
uv run python lib/task_manager.py table
uv run python lib/task_manager.py list
```

Delete these 4 lines.

- [ ] **Step 3: Update tasks.json schema documentation**

Find the existing `tasks.json` example in the Key Concepts section (search for `"blockedBy": []`). The current example is:

```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement feature X",
      "description": "Detailed description...",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2"]
    }
  ]
}
```

Replace with:

```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Implement feature X",
      "description": "Detailed description...",
      "agent": "developer",
      "status": "pending",
      "needs_validation": true,
      "validated": false,
      "blockedBy": [],
      "blocks": ["T2"]
    }
  ]
}
```

- [ ] **Step 4: Add `validate_tasks` to status.yml documentation**

Find the `status.yml` example in CLAUDE.md (search for `checkin_interval_minutes`). Add `validate_tasks` to the example and its description:

```yaml
validate_tasks: true                   # Global toggle: PM validates developer work before marking complete
```

- [ ] **Step 5: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md with validation fields and remove task_manager references"
```

---

### Task 6: Remove task_manager.py and its references

**Files:**
- DELETE: `lib/task_manager.py`
- DELETE: `tests/unit/test_task_manager.py`
- Modify: `lib/__init__.py:20,35,44`
- Modify: `tests/unit/test_init.py:33-35`
- Modify: `tests/e2e/test-task-table-format.sh:407-493`
- Modify: `tests/e2e/tests-to-implement.md:62`

- [ ] **Step 1: Delete the module and its unit tests**

```bash
cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato
rm lib/task_manager.py
rm tests/unit/test_task_manager.py
```

- [ ] **Step 2: Remove TaskManager from lib/__init__.py**

In `lib/__init__.py`, remove line 20:

```python
from lib.task_manager import TaskManager, assign_task
```

Remove `"TaskManager"` from the `__all__` list (line 35).

Remove `"assign_task"` from the `__all__` list (line 44).

- [ ] **Step 3: Remove TaskManager test from test_init.py**

In `tests/unit/test_init.py`, remove lines 33-35:

```python
    def test_task_manager_class(self):
        from lib import TaskManager
        assert TaskManager is not None
```

- [ ] **Step 4: Remove task_manager.py tests from E2E test file**

In `tests/e2e/test-task-table-format.sh`, remove tests 8, 9, and 10 (lines 407-493 approximately — everything from `# Test 8: task_manager.py table` to the end of `# Test 10`). These are the last 3 tests in the file that specifically test `task_manager.py table`.

- [ ] **Step 5: Remove task_manager.py item from tests-to-implement.md**

In `tests/e2e/tests-to-implement.md`, remove line 62:

```
- [ ] **test-agent-task-assignment.sh** - task_manager.py assign functionality
```

- [ ] **Step 6: Run the full test suite to verify nothing breaks**

```bash
cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato && bin/run-tests.sh
```

Expected: All tests pass (count will decrease by the number of tests in the deleted `test_task_manager.py` and the removed `test_init.py` test).

- [ ] **Step 7: Commit**

```bash
git add -A
git commit -m "chore: remove unused task_manager.py module and all references"
```

---

### Task 7: Run full test suite and verify

**Files:**
- None (verification only)

- [ ] **Step 1: Run unit tests**

```bash
cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato && bin/run-tests.sh
```

Expected: All tests pass.

- [ ] **Step 2: Run E2E tests**

```bash
cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato && bash tests/e2e/run-all-tests.sh
```

Expected: All tests pass.

- [ ] **Step 3: Verify status.yml creation includes validate_tasks**

```bash
cd /Users/personal/dev/tools/claude-code-plugins/plugins/yato && uv run python -c "
from lib.workflow_ops import WorkflowOps
import tempfile, yaml, os
with tempfile.TemporaryDirectory() as d:
    folder = WorkflowOps.create_workflow_folder(d, 'test', session='s')
    with open(os.path.join(d, '.workflow', folder, 'status.yml')) as f:
        data = yaml.safe_load(f)
    assert data['validate_tasks'] is True, 'validate_tasks not found'
    print('validate_tasks: OK')
"
```

Expected: `validate_tasks: OK`
