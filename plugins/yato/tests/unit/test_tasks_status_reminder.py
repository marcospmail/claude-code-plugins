"""Unit tests for hooks/scripts/tasks-status-reminder.py hook."""

import json
import subprocess
import sys
import os

import pytest
import yaml


HOOK_SCRIPT = os.path.join(
    os.path.dirname(__file__), "..", "..", "hooks", "scripts", "tasks-status-reminder.py"
)


def run_hook(hook_input: dict) -> dict:
    """Run the hook script with given input and return parsed JSON output."""
    result = subprocess.run(
        [sys.executable, HOOK_SCRIPT],
        input=json.dumps(hook_input),
        capture_output=True,
        text=True,
    )
    assert result.returncode == 0
    return json.loads(result.stdout)


class TestAgentRosterWithAgentsYml:
    """Tests for roster injection when agents.yml is present."""

    def test_tasks_json_with_multiple_agents_includes_roster(self, tmp_workflow_with_agents):
        """When editing tasks.json and agents.yml has multiple agents, systemMessage includes roster."""
        tasks_path = str(tmp_workflow_with_agents / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        assert output["continue"] is True
        msg = output["systemMessage"]
        assert "TEAM ROSTER" in msg
        assert "developer" in msg
        assert "qa" in msg
        assert "2 agents" in msg

    def test_tasks_json_with_one_agent_includes_roster(self, tmp_workflow):
        """Even with a single agent, roster should still appear."""
        agents_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "%5", "session": "s", "window": 0, "model": "opus"},
            "agents": [
                {"name": "developer", "role": "developer", "pane_id": "%6", "session": "s", "window": 1, "model": "sonnet"},
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
        assert "developer" in msg
        assert "1 agents" in msg or "1 agent" in msg

    def test_tasks_json_with_five_agents_lists_all(self, tmp_workflow):
        """Full team of 5 agents should all appear in roster."""
        agent_names = ["developer", "qa", "code-reviewer", "devops", "designer"]
        agents_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "%5", "session": "s", "window": 0, "model": "opus"},
            "agents": [
                {"name": name, "role": name, "pane_id": f"%{6+i}", "session": "s", "window": 1+i, "model": "sonnet"}
                for i, name in enumerate(agent_names)
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
        assert "5 agents" in msg
        for name in agent_names:
            assert name in msg


class TestAgentRosterWithoutAgentsYml:
    """Tests for when agents.yml is missing or invalid."""

    def test_tasks_json_without_agents_yml_has_no_roster(self, tmp_workflow):
        """When agents.yml is missing, systemMessage should have status rules but no roster."""
        tasks_path = str(tmp_workflow / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        assert output["continue"] is True
        msg = output["systemMessage"]
        # Status rules still present
        assert "NEVER" in msg
        # No roster
        assert "TEAM ROSTER" not in msg

    def test_tasks_json_with_malformed_agents_yml(self, tmp_workflow):
        """When agents.yml is malformed YAML, gracefully fall back to no roster."""
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text("{{invalid yaml: [broken")

        tasks_path = str(tmp_workflow / "tasks.json")
        hook_input = {"toolInput": {"file_path": tasks_path}}

        output = run_hook(hook_input)

        assert output["continue"] is True
        msg = output["systemMessage"]
        assert "TEAM ROSTER" not in msg
        # Status rules still work
        assert "NEVER" in msg


class TestNonTasksJsonFiles:
    """Tests for files that are NOT tasks.json."""

    def test_non_tasks_json_returns_continue_no_message(self):
        """Non-tasks.json files should get continue:true with no systemMessage."""
        hook_input = {"toolInput": {"file_path": "/project/src/main.py"}}

        output = run_hook(hook_input)

        assert output["continue"] is True
        assert "systemMessage" not in output

    def test_empty_file_path_returns_continue(self):
        """Empty file_path should return continue:true with no systemMessage."""
        hook_input = {"toolInput": {"file_path": ""}}

        output = run_hook(hook_input)

        assert output["continue"] is True
        assert "systemMessage" not in output
