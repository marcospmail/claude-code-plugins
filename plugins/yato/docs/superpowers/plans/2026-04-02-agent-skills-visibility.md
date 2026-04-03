# Agent Skills Visibility & Self-Contained CLAUDE.md — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make agent descriptions (including mandatory skills) visible to the PM at task-planning time, and consolidate agent config into a self-contained CLAUDE.md.

**Architecture:** Enrich agent YAML descriptions with mandatory skill info, surface descriptions in the PM roster hook, inline instructions + constraints into the agent CLAUDE.md template, and remove the now-redundant `instructions.md` and `constraints.md` files.

**Tech Stack:** Python, Jinja2, YAML, pytest

---

### Task 1: Update Agent YAML Descriptions

**Files:**
- Modify: `agents/code-reviewer.yml`
- Modify: `agents/security-reviewer.yml`

- [ ] **Step 1: Update code-reviewer.yml description**

```yaml
name: code-reviewer
description: "Code review agent. Must run /code-review skill on every task. Reviews code quality, best practices, and security (read-only)"
can_modify_code: false
default_model: opus
effort: medium
instructions: |
  - Run /code-review skill on every task assignment
  - Review code for quality and best practices
  - Check for security vulnerabilities
  - Provide constructive feedback
  - Request changes from developers - do NOT fix yourself
  - Approve only when all issues are addressed
```

- [ ] **Step 2: Update security-reviewer.yml description**

```yaml
name: security-reviewer
description: "Security analysis agent. Must run /security-review skill on every task. Reviews code for vulnerabilities and OWASP concerns (read-only)"
can_modify_code: false
default_model: opus
effort: medium
instructions: |
  - Run /security-review skill on every task assignment
  - Review code for security vulnerabilities
  - Check for OWASP top 10 issues
  - Provide security recommendations
  - Request changes from developers
```

- [ ] **Step 3: Commit**

```bash
git add agents/code-reviewer.yml agents/security-reviewer.yml
git commit -m "feat(agents): enrich descriptions with mandatory skills"
```

---

### Task 2: Surface Agent Descriptions in PM Roster Hook

**Files:**
- Modify: `hooks/scripts/tasks-status-reminder.py`
- Test: `tests/unit/test_tasks_status_reminder.py`

- [ ] **Step 1: Write failing tests for the new roster format**

Add these tests to `tests/unit/test_tasks_status_reminder.py`:

```python
class TestAgentRosterWithDescriptions:
    """Tests for roster injection with agent descriptions from predefined YAMLs."""

    def test_roster_includes_agent_descriptions(self, tmp_workflow_with_agents):
        """Roster should show descriptions from predefined agent YAMLs."""
        tasks_path = str(tmp_workflow_with_agents / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        msg = output["systemMessage"]
        assert "TEAM ROSTER" in msg
        # Should contain description text, not just names
        assert "- developer:" in msg
        assert "- qa:" in msg

    def test_roster_shows_mandatory_skills(self, tmp_workflow):
        """When agent has mandatory skills in description, they appear in roster."""
        agents_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "%5", "session": "s", "window": 0, "model": "opus"},
            "agents": [
                {"name": "reviewer", "role": "code-reviewer", "pane_id": "%6", "session": "s", "window": 1, "model": "opus"},
            ],
        }
        agents_file = tmp_workflow / "agents.yml"
        with open(agents_file, "w") as f:
            yaml.dump(agents_data, f, default_flow_style=False)

        tasks_path = str(tmp_workflow / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        msg = output["systemMessage"]
        assert "TEAM ROSTER" in msg
        assert "/code-review" in msg

    def test_roster_falls_back_to_name_when_no_yaml(self, tmp_workflow):
        """Unknown roles without a predefined YAML fall back to showing agent name only."""
        agents_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "%5", "session": "s", "window": 0, "model": "opus"},
            "agents": [
                {"name": "custom-agent", "role": "custom-unknown-role", "pane_id": "%6", "session": "s", "window": 1, "model": "sonnet"},
            ],
        }
        agents_file = tmp_workflow / "agents.yml"
        with open(agents_file, "w") as f:
            yaml.dump(agents_data, f, default_flow_style=False)

        tasks_path = str(tmp_workflow / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        msg = output["systemMessage"]
        assert "TEAM ROSTER" in msg
        assert "custom-agent" in msg

    def test_roster_includes_mandatory_skill_instruction(self, tmp_workflow_with_agents):
        """Roster should include instruction about mandatory skills."""
        tasks_path = str(tmp_workflow_with_agents / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        msg = output["systemMessage"]
        assert "mandatory skill" in msg.lower() or "mandatory" in msg.lower()
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/run-tests.sh --module tasks_status_reminder`
Expected: FAIL — current roster format doesn't include descriptions

- [ ] **Step 3: Update `get_agent_roster` in tasks-status-reminder.py**

Replace the `get_agent_roster` function:

```python
def get_agent_roster(file_path: str) -> Optional[str]:
    """Extract agent roster with descriptions from agents.yml and predefined agent YAMLs."""
    try:
        workflow_dir = os.path.dirname(file_path)
        agents_yml_path = os.path.join(workflow_dir, "agents.yml")

        with open(agents_yml_path, "r") as f:
            agents_data = yaml.safe_load(f)

        agents_list = agents_data["agents"]
        count = len(agents_list)

        # Load predefined agent descriptions
        yato_path = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        predefined_agents_dir = os.path.join(yato_path, "agents")

        agent_lines = []
        for agent in agents_list:
            name = agent["name"]
            role = agent.get("role", name)
            description = _load_agent_description(predefined_agents_dir, role)
            if description:
                agent_lines.append(f"- {name}: {description}")
            else:
                agent_lines.append(f"- {name}")

        roster_list = "\n".join(agent_lines)
        return (
            f"TEAM ROSTER ({count} agents):\n"
            f"{roster_list}\n\n"
            f"Assign tasks to all applicable agents. "
            f"When an agent's description mentions a mandatory skill/command, include it in the task instructions."
        )
    except (FileNotFoundError, KeyError, TypeError, yaml.YAMLError):
        return None


def _load_agent_description(agents_dir: str, role: str) -> Optional[str]:
    """Load description for a role from predefined agent YAML."""
    yml_path = os.path.join(agents_dir, f"{role}.yml")
    try:
        with open(yml_path, "r") as f:
            data = yaml.safe_load(f)
        return data.get("description")
    except (FileNotFoundError, yaml.YAMLError, AttributeError):
        return None
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/run-tests.sh --module tasks_status_reminder`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add hooks/scripts/tasks-status-reminder.py tests/unit/test_tasks_status_reminder.py
git commit -m "feat(hooks): surface agent descriptions in PM roster"
```

---

### Task 3: Expand CLAUDE.md Template with Inlined Instructions and Constraints

**Files:**
- Modify: `lib/templates/agent_claude.md.j2`

- [ ] **Step 1: Rewrite the CLAUDE.md template**

Replace the entire content of `lib/templates/agent_claude.md.j2`:

```jinja2
# Agent Configuration

## Identity
- Read [identity.yml](./identity.yml) for your role, pane_id, model, and capabilities

## Instructions

### Role
{{ agent_purpose }}

### Description
{{ role_description }}

### Responsibilities
{{ responsibilities }}

### Communication
- Notify PM using: `/notify-pm [STATUS] message`
- The skill auto-detects PM location from agents.yml
- Check agent-tasks.md for your assigned tasks

#### How to Communicate:
- **If you need information**: `/notify-pm [BLOCKED] Need database connection details`
- **If you have a question**: `/notify-pm [HELP] Should I apply migration to production?`
- **If you're done**: `/notify-pm [DONE] Completed task X`
- **If you're stuck**: `/notify-pm [BLOCKED] Cannot proceed because Y`

#### The PM Will:
- Ask the user questions on your behalf
- Provide you with answers and decisions
- Assign you different work if blocked
- Coordinate all user communication
{% if role == "pm" %}

### Task Management

tasks.json is the SINGLE SOURCE OF TRUTH. When adding or modifying tasks:
1. **FIRST** update tasks.json with the new/changed task
2. **THEN** update the agent's agent-tasks.md file

### Communicating with Agents

**CRITICAL**: You MUST use `/send-to-agent` to communicate with team agents. They run in separate tmux windows and can ONLY be reached via tmux.
Do NOT use the built-in SendMessage tool — it sends to in-process subagents, NOT to tmux-based Yato agents. Messages sent via SendMessage will be lost silently.

Use `/send-to-agent` to send messages to agents:
- `/send-to-agent developer "You have new tasks. Read your agent-tasks.md for details."`
- `/send-to-agent qa "Please verify T1 — check acceptance criteria in your agent-tasks.md."`

Agent names are listed in agents.yml. Names may differ from roles (e.g., "discoverer" with role "qa", "impl" with role "developer").
The `/send-to-agent` skill handles looking up the agent's tmux window automatically.
{% endif %}

### Waiting for Dependencies

If you need to wait for another agent to complete work (e.g., waiting for a file to be created):

1. **Check once** - verify if the dependency is ready
2. **If not ready after 3 checks** (30-60 seconds each): Notify PM with status
3. **Maximum 5 retries** - after 5 attempts, notify PM you are BLOCKED and stop polling
4. **Increasing delays** - wait 30s, then 60s, then 2min between checks

Example:
```bash
# Limited retries with PM notification
for i in 1 2 3 4 5; do
  if [[ -f "expected_file.md" ]]; then break; fi
  sleep $((i * 30))
done
if [[ ! -f "expected_file.md" ]]; then
  # Use /notify-pm skill: /notify-pm [BLOCKED] Waited 5 times for expected_file.md - still missing
fi
```

Your PM can help resolve blocking dependencies. Notify early.

## Constraints

{{ constraints_content }}
{% if role == "pm" %}

## Communication Rules
- NEVER use the built-in SendMessage tool — it cannot reach tmux agents
- ALWAYS use `/send-to-agent <name> "message"` to communicate with team agents
{% endif %}

## Tasks
- Read [agent-tasks.md](./agent-tasks.md) for your current tasks
- Monitor this file continuously - PM adds tasks here
- CHECK OFF items as you complete them (change [ ] to [x])
{% if is_pm %}

## Planning Briefing
- Read [planning-briefing.md](./planning-briefing.md) for your complete planning workflow
- This is your primary operational guide - follow its steps in order
{% endif %}

## Important Notes

- Re-read agent-tasks.md frequently as PM updates it with new tasks
- If you encounter any issues, notify your PM immediately

## Quick Reference

- Your PM: See agents.yml for PM pane_id
- Project: {{ project_path }}
- Workflow: {{ workflow_name }}
```

- [ ] **Step 2: Commit**

```bash
git add lib/templates/agent_claude.md.j2
git commit -m "feat(templates): expand CLAUDE.md with inlined instructions and constraints"
```

---

### Task 4: Update agent_manager.py to Pass Content to CLAUDE.md Template

**Files:**
- Modify: `lib/agent_manager.py`
- Test: `tests/unit/test_agent_manager.py`

- [ ] **Step 1: Write failing tests**

Update existing tests and add new ones in `tests/unit/test_agent_manager.py`:

```python
class TestInitAgentFilesSelfContained:
    """Tests for self-contained CLAUDE.md (no instructions.md or constraints.md)."""

    def test_no_instructions_md_generated(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "mydev", "developer", "sonnet", "001-test-feature"
        )
        assert result is not None
        agent_dir = Path(result)
        assert not (agent_dir / "instructions.md").exists()

    def test_no_constraints_md_generated(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "mydev", "developer", "sonnet", "001-test-feature"
        )
        assert result is not None
        agent_dir = Path(result)
        assert not (agent_dir / "constraints.md").exists()

    def test_claude_md_contains_instructions(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "mydev", "developer", "sonnet", "001-test-feature"
        )
        claude_md = (Path(result) / "CLAUDE.md").read_text()
        assert "## Instructions" in claude_md
        assert "Responsibilities" in claude_md

    def test_claude_md_contains_constraints(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "mydev", "developer", "sonnet", "001-test-feature"
        )
        claude_md = (Path(result) / "CLAUDE.md").read_text()
        assert "## Constraints" in claude_md
        assert "System Constraints" in claude_md

    def test_pm_claude_md_has_pm_constraints(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "pm", "pm", "opus", "001-test-feature"
        )
        claude_md = (Path(result) / "CLAUDE.md").read_text()
        assert "PM Constraints" in claude_md or "PM-Specific Constraints" in claude_md
        assert "GOLDEN RULE" in claude_md

    def test_developer_claude_md_has_system_constraints(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "dev", "developer", "sonnet", "001-test-feature"
        )
        claude_md = (Path(result) / "CLAUDE.md").read_text()
        assert "NEVER communicate directly with the user" in claude_md

    def test_claude_md_references_identity_yml(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "dev", "developer", "sonnet", "001-test-feature"
        )
        claude_md = (Path(result) / "CLAUDE.md").read_text()
        assert "identity.yml" in claude_md

    def test_claude_md_references_agent_tasks(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "dev", "developer", "sonnet", "001-test-feature"
        )
        claude_md = (Path(result) / "CLAUDE.md").read_text()
        assert "agent-tasks.md" in claude_md
```

- [ ] **Step 2: Run tests to verify they fail**

Run: `bin/run-tests.sh --module agent_manager`
Expected: FAIL — instructions.md and constraints.md still generated, CLAUDE.md doesn't contain inlined content

- [ ] **Step 3: Update `init_agent_files` in agent_manager.py**

Replace the instructions.md generation block (lines 256-270), the constraints.md generation block (lines 272-330), and the CLAUDE.md generation block (lines 332-338) with:

```python
        # Build instructions content for inlining into CLAUDE.md
        if role_config.get("instructions"):
            responsibilities_str = role_config["instructions"].strip()
        else:
            responsibilities_str = "\n".join(f"- {r}" for r in role_config.get("responsibilities", []))

        # Build constraints content for inlining into CLAUDE.md
        system_constraints = """## System Constraints

- NEVER communicate directly with the user
- DO NOT ask the user questions using AskUserQuestion tool
- DO NOT wait for user input or confirmation
- DO NOT output messages intended for the user
- NEVER stop working silently - always notify PM
- DO NOT enter infinite polling loops when waiting for dependencies
"""

        if role == "pm":
            constraints_content = """# PM Constraints

## System Constraints

- NEVER stop working silently - always notify the user
- DO NOT enter infinite polling loops when waiting for dependencies

## PM-Specific Constraints

- You CANNOT modify any code files
- Do NOT write implementation code
- Do NOT run tests directly (delegate to QA agent)
- Do NOT make git commits (delegate to agents)
- Do NOT use TodoWrite tool (forbidden - use workflow tasks.json instead)
- Do NOT use Task tool or sub-agents to CREATE TEAM MEMBERS (ALWAYS use create-team.sh directly via Bash). Task tool IS allowed for other purposes (e.g., Explorer agents for codebase analysis).
- Do NOT make technical implementation decisions without delegating
- Do NOT update PRD with technical details you invented (only use user-provided requirements)
- Do NOT use Write/Edit/Bash tools for implementation work
- NEVER call cancel-checkin.sh - the check-in loop stops AUTOMATICALLY when all tasks are completed
  (only the USER can stop the loop early via /cancel-checkin if they choose to)
- NEVER skip updating tasks.json before modifying agent-tasks.md
- NEVER write to agent-tasks.md without a corresponding entry in tasks.json

**GOLDEN RULE: If it's not coordination/planning, DELEGATE IT to an agent via /send-to-agent.**

## Required Actions
- ALWAYS delegate implementation to agents
- ALWAYS update tasks.json when tasks change status
- ALWAYS provide specific, actionable feedback
- ALWAYS use `/send-to-agent <agent-name> "message"` to communicate with agents
"""
        else:
            constraints_content = f"""{system_constraints}
## Project Constraints

(No project-specific constraints configured)
"""

        # Create CLAUDE.md (self-contained with instructions + constraints)
        claude_content = self._render_template("agent_claude.md.j2", {
            "project_path": project_path,
            "workflow_name": workflow_name,
            "is_pm": role == "pm",
            "role": role,
            "agent_purpose": role_config["purpose"],
            "role_description": role_description,
            "responsibilities": responsibilities_str,
            "constraints_content": constraints_content,
        })
        (agent_dir / "CLAUDE.md").write_text(claude_content)
```

Also update the docstring of `init_agent_files` (line 183-188) to reflect the new file list:

```python
        """
        Create agent configuration files (without tmux window).

        This creates the agent's directory with:
        - identity.yml (window field empty until tmux window created)
        - CLAUDE.md (self-contained: instructions + constraints inlined)
        - agent-tasks.md
```

And update the class docstring (lines 56-64):

```python
    """
    Manages agent creation and lifecycle.

    Agents are stored in .workflow/<workflow>/agents/<name>/ with:
    - identity.yml
    - CLAUDE.md (self-contained: instructions + constraints inlined)
    - agent-tasks.md
    """
```

- [ ] **Step 4: Run tests to verify they pass**

Run: `bin/run-tests.sh --module agent_manager`
Expected: PASS

- [ ] **Step 5: Commit**

```bash
git add lib/agent_manager.py tests/unit/test_agent_manager.py
git commit -m "feat(agent-manager): inline instructions and constraints into CLAUDE.md"
```

---

### Task 5: Update Existing Tests for Removed Files

**Files:**
- Modify: `tests/unit/test_agent_manager.py`

- [ ] **Step 1: Update test_creates_all_files_developer**

In `TestInitAgentFiles.test_creates_all_files_developer`, remove assertions for `instructions.md` and `constraints.md`:

Replace:
```python
        assert (agent_dir / "identity.yml").exists()
        assert (agent_dir / "instructions.md").exists()
        assert (agent_dir / "constraints.md").exists()
        assert (agent_dir / "CLAUDE.md").exists()
        assert (agent_dir / "agent-tasks.md").exists()
```

With:
```python
        assert (agent_dir / "identity.yml").exists()
        assert (agent_dir / "CLAUDE.md").exists()
        assert (agent_dir / "agent-tasks.md").exists()
        # instructions.md and constraints.md no longer generated (inlined into CLAUDE.md)
        assert not (agent_dir / "instructions.md").exists()
        assert not (agent_dir / "constraints.md").exists()
```

- [ ] **Step 2: Update test_pm_constraints_differ_from_agent**

Replace the test that reads `constraints.md` with one that reads `CLAUDE.md`:

```python
    def test_pm_constraints_differ_from_agent(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        pm_dir = mgr.init_agent_files(
            str(project), "pm", "pm", "opus", "001-test-feature"
        )
        dev_dir = mgr.init_agent_files(
            str(project), "dev", "developer", "sonnet", "001-test-feature"
        )
        pm_claude = (Path(pm_dir) / "CLAUDE.md").read_text()
        dev_claude = (Path(dev_dir) / "CLAUDE.md").read_text()
        assert "PM Constraints" in pm_claude or "PM-Specific Constraints" in pm_claude
        assert "PM Constraints" not in dev_claude
```

- [ ] **Step 3: Update test_directory_rename_on_disk**

In `TestRenameAgentDiskRename.test_directory_rename_on_disk`, remove the line that creates `instructions.md` and checks for it:

Replace:
```python
        (old_dir / "instructions.md").write_text("# Instructions\n")
```
```python
        assert (new_dir / "instructions.md").exists()
```

With just removing those lines (the test only needs identity.yml to validate rename behavior).

- [ ] **Step 4: Run all tests**

Run: `bin/run-tests.sh`
Expected: ALL PASS

- [ ] **Step 5: Commit**

```bash
git add tests/unit/test_agent_manager.py
git commit -m "test: update tests for removed instructions.md and constraints.md"
```

---

### Task 6: Delete Unused Templates

**Files:**
- Delete: `lib/templates/agent_instructions.md.j2`
- Delete: `lib/templates/constraints.example.md.j2`

- [ ] **Step 1: Verify no other code references these templates**

Run:
```bash
grep -r "agent_instructions.md.j2\|constraints.example.md.j2" lib/ hooks/ skills/ bin/ --include="*.py" --include="*.sh" --include="*.md"
```

Expected: No results (agent_manager.py no longer references them after Task 4).

- [ ] **Step 2: Delete the templates**

```bash
rm lib/templates/agent_instructions.md.j2
rm lib/templates/constraints.example.md.j2
```

- [ ] **Step 3: Run all tests to confirm nothing breaks**

Run: `bin/run-tests.sh`
Expected: ALL PASS

- [ ] **Step 4: Commit**

```bash
git add -A lib/templates/agent_instructions.md.j2 lib/templates/constraints.example.md.j2
git commit -m "chore: remove unused agent_instructions.md.j2 and constraints.example.md.j2 templates"
```

---

### Task 7: Update CLAUDE.md Documentation

**Files:**
- Modify: `CLAUDE.md`

- [ ] **Step 1: Update the agent file list in CLAUDE.md**

In the CLAUDE.md project documentation, update references to the agent file structure. Find the section that lists agent files and update it.

In the "Workflow System" section, update the agent directory listing:

Replace:
```
        ├── developer/
        │   ├── identity.yml
        │   ├── instructions.md
        │   ├── constraints.example.md
        │   ├── CLAUDE.md
        │   └── agent-tasks.md
```

With:
```
        ├── developer/
        │   ├── identity.yml
        │   ├── CLAUDE.md
        │   └── agent-tasks.md
```

Also update the AgentManager class docstring reference and the `init_agent_files` description if they appear in CLAUDE.md.

- [ ] **Step 2: Run all tests one final time**

Run: `bin/run-tests.sh`
Expected: ALL PASS

- [ ] **Step 3: Commit**

```bash
git add CLAUDE.md
git commit -m "docs: update CLAUDE.md for self-contained agent CLAUDE.md"
```
