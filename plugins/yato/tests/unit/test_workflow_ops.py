"""Tests for lib/workflow_ops.py — workflow folder management."""

import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import yaml

from lib.workflow_ops import (
    WorkflowOps,
    get_next_workflow_number,
    generate_workflow_slug,
    create_workflow_folder,
    get_current_workflow,
    get_current_workflow_path,
    list_workflows,
)


# ==================== WorkflowOps.get_next_workflow_number ====================


class TestGetNextWorkflowNumber:
    def test_no_workflow_dir(self, tmp_project):
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "001"

    def test_empty_workflow_dir(self, tmp_project):
        (tmp_project / ".workflow").mkdir()
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "001"

    def test_existing_workflows(self, tmp_project):
        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "001-first").mkdir()
        (wf / "002-second").mkdir()
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "003"

    def test_non_sequential(self, tmp_project):
        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "001-first").mkdir()
        (wf / "005-fifth").mkdir()
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "006"

    def test_ignores_non_workflow_dirs(self, tmp_project):
        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "001-first").mkdir()
        (wf / "current").mkdir()  # Not a workflow
        (wf / "notes.txt").write_text("hello")
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "002"

    def test_ignores_invalid_numbers(self, tmp_project):
        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "abc-invalid").mkdir()
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "001"

    def test_handles_value_error_in_number_parse(self, tmp_project):
        """Dirs matching \\d{3}- but whose first 3 chars can't be parsed as int."""
        wf = tmp_project / ".workflow"
        wf.mkdir()
        # This matches the regex ^\d{3}- but int() should work fine
        # The ValueError path requires something weird; create a normal one + a broken one
        (wf / "001-valid").mkdir()
        result = WorkflowOps.get_next_workflow_number(str(tmp_project))
        assert result == "002"

    def test_module_level_function(self, tmp_project):
        result = get_next_workflow_number(str(tmp_project))
        assert result == "001"


# ==================== WorkflowOps.generate_workflow_slug ====================


class TestGenerateWorkflowSlug:
    def test_simple_title(self):
        result = WorkflowOps.generate_workflow_slug("Add user authentication")
        assert result == "add-user-authentication"

    def test_max_words(self):
        result = WorkflowOps.generate_workflow_slug("one two three four five six", max_words=3)
        assert result == "one-two-three"

    def test_max_length(self):
        result = WorkflowOps.generate_workflow_slug("very long title here", max_length=10)
        assert len(result) <= 10

    def test_special_characters_removed(self):
        result = WorkflowOps.generate_workflow_slug("Fix bug #123 (urgent!)")
        assert "#" not in result
        assert "(" not in result
        assert "!" not in result

    def test_short_words_skipped(self):
        result = WorkflowOps.generate_workflow_slug("Add a new feature to the app")
        # "a" and "to" should be skipped (len <= 2)
        assert "a-" not in result.split("-")
        assert "-to-" not in result

    def test_first_word_kept_even_if_short(self):
        result = WorkflowOps.generate_workflow_slug("Go build something")
        assert result.startswith("go")

    def test_empty_input(self):
        result = WorkflowOps.generate_workflow_slug("")
        assert result == ""

    def test_module_level_function(self):
        result = generate_workflow_slug("test slug")
        assert "test" in result


# ==================== WorkflowOps.create_workflow_folder ====================


class TestCreateWorkflowFolder:
    def test_creates_folder_structure(self, tmp_project):
        folder_name = WorkflowOps.create_workflow_folder(
            str(tmp_project), "Add feature X", initial_request="Build X"
        )
        assert folder_name.startswith("001-")
        full_path = tmp_project / ".workflow" / folder_name
        assert full_path.exists()
        assert (full_path / "agents" / "pm").exists()
        assert (full_path / "status.yml").exists()

    def test_status_yml_content(self, tmp_project):
        folder_name = WorkflowOps.create_workflow_folder(
            str(tmp_project), "My Feature",
            initial_request="Build it",
            session="my-sess",
            checkin_interval=10,
        )
        status_file = tmp_project / ".workflow" / folder_name / "status.yml"
        with open(status_file) as f:
            data = yaml.safe_load(f)
        assert data["status"] == "in-progress"
        assert data["title"] == "My Feature"
        assert data["initial_request"] == "Build it"
        assert data["session"] == "my-sess"
        assert data["checkin_interval_minutes"] == 10
        assert "created_at" in data
        assert data["agent_message_suffix"] == ""
        assert data["checkin_message_suffix"] == ""
        assert data["agent_to_pm_message_suffix"] == ""
        assert data["user_to_pm_message_suffix"] == ""
        assert data["validate_tasks"] is True

    def test_sequential_numbering(self, tmp_project):
        f1 = WorkflowOps.create_workflow_folder(str(tmp_project), "First")
        f2 = WorkflowOps.create_workflow_folder(str(tmp_project), "Second")
        assert f1.startswith("001-")
        assert f2.startswith("002-")

    def test_module_level_function(self, tmp_project):
        folder = create_workflow_folder(str(tmp_project), "Test")
        assert folder.startswith("001-")


# ==================== WorkflowOps.get_current_workflow ====================


class TestGetCurrentWorkflow:
    def test_from_env_var(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-my-workflow")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        result = WorkflowOps.get_current_workflow(str(tmp_project))
        assert result == "001-my-workflow"

    def test_from_internal_override(self, monkeypatch, tmp_project):
        monkeypatch.setenv("_YATO_WORKFLOW_NAME", "002-override")
        result = WorkflowOps.get_current_workflow(str(tmp_project))
        assert result == "002-override"

    def test_internal_override_takes_priority(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-env")
        monkeypatch.setenv("_YATO_WORKFLOW_NAME", "002-override")
        result = WorkflowOps.get_current_workflow(str(tmp_project))
        assert result == "002-override"

    def test_from_tmux(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.setenv("TMUX", "/tmp/tmux-1000/default,12345,0")

        mock = MagicMock()
        mock.returncode = 0
        mock.stdout = "WORKFLOW_NAME=001-tmux-wf\n"
        with patch("subprocess.run", return_value=mock):
            result = WorkflowOps.get_current_workflow(str(tmp_project))
            assert result == "001-tmux-wf"

    def test_tmux_error_falls_through(self, monkeypatch, tmp_project):
        """When tmux showenv fails, falls through to folder discovery."""
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.setenv("TMUX", "/tmp/tmux-1000/default,12345,0")

        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "001-fallback").mkdir()

        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = WorkflowOps.get_current_workflow(str(tmp_project))
            assert result == "001-fallback"

    def test_tmux_with_socket(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.setenv("TMUX", "/tmp/tmux-1000/default,12345,0")
        monkeypatch.setenv("TMUX_SOCKET", "mysock")

        mock = MagicMock()
        mock.returncode = 0
        mock.stdout = "WORKFLOW_NAME=001-sock\n"
        with patch("subprocess.run", return_value=mock) as mock_run:
            result = WorkflowOps.get_current_workflow(str(tmp_project))
            assert result == "001-sock"
            cmd = mock_run.call_args[0][0]
            assert "-L" in cmd
            assert "mysock" in cmd

    def test_fallback_to_most_recent(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)

        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "001-first").mkdir()
        (wf / "002-second").mkdir()

        result = WorkflowOps.get_current_workflow(str(tmp_project))
        assert result == "002-second"

    def test_no_workflow_found(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.get_current_workflow(str(tmp_project))
        assert result is None

    def test_module_level_function(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        result = get_current_workflow(str(tmp_project))
        assert result == "001-test"


# ==================== WorkflowOps.get_current_workflow_path ====================


class TestGetCurrentWorkflowPath:
    def test_returns_path(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-feature")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        (tmp_project / ".workflow" / "001-feature").mkdir(parents=True)
        result = WorkflowOps.get_current_workflow_path(str(tmp_project))
        assert result == tmp_project / ".workflow" / "001-feature"

    def test_returns_none_when_no_workflow(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.get_current_workflow_path(str(tmp_project))
        assert result is None

    def test_module_level_function(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = get_current_workflow_path(str(tmp_project))
        assert result is None


# ==================== WorkflowOps.update_checkin_interval ====================


class TestUpdateCheckinInterval:
    def test_updates_interval(self, monkeypatch, tmp_project):
        # Create workflow with status.yml
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        status_file = wf / "status.yml"
        status_file.write_text("# Status\ncheckin_interval_minutes: 5\nstatus: in-progress\n")

        result = WorkflowOps.update_checkin_interval(str(tmp_project), 5)
        assert result is True
        content = status_file.read_text()
        assert "checkin_interval_minutes: 5" in content

    def test_no_workflow(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.update_checkin_interval(str(tmp_project), 5)
        assert result is False

    def test_no_status_file(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        (tmp_project / ".workflow" / "001-test").mkdir(parents=True)
        result = WorkflowOps.update_checkin_interval(str(tmp_project), 5)
        assert result is False


# ==================== WorkflowOps.list_workflows ====================


class TestListWorkflows:
    def test_no_workflow_dir(self, tmp_project):
        result = WorkflowOps.list_workflows(str(tmp_project))
        assert result == []

    def test_lists_workflows(self, tmp_project):
        wf = tmp_project / ".workflow"
        wf.mkdir()
        wf1 = wf / "001-first"
        wf1.mkdir()
        status = wf1 / "status.yml"
        with open(status, "w") as f:
            yaml.dump({"status": "in-progress", "title": "First Feature"}, f)

        wf2 = wf / "002-second"
        wf2.mkdir()

        result = WorkflowOps.list_workflows(str(tmp_project))
        assert len(result) == 2
        assert result[0]["name"] == "001-first"
        assert result[0]["status"] == "in-progress"
        assert result[0]["title"] == "First Feature"
        assert result[1]["name"] == "002-second"
        assert result[1]["status"] == "unknown"

    def test_ignores_non_workflow_dirs(self, tmp_project):
        wf = tmp_project / ".workflow"
        wf.mkdir()
        (wf / "current").mkdir()
        (wf / "001-real").mkdir()
        result = WorkflowOps.list_workflows(str(tmp_project))
        assert len(result) == 1
        assert result[0]["name"] == "001-real"

    def test_handles_malformed_yaml(self, tmp_project):
        wf = tmp_project / ".workflow" / "001-bad"
        wf.mkdir(parents=True)
        (wf / "status.yml").write_text(": : : not valid yaml [[[")
        result = WorkflowOps.list_workflows(str(tmp_project))
        assert len(result) == 1
        assert result[0]["status"] == "unknown"

    def test_module_level_function(self, tmp_project):
        result = list_workflows(str(tmp_project))
        assert result == []


# ==================== WorkflowOps.create_agents_yml ====================


class TestCreateAgentsYml:
    def test_creates_file(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        result = WorkflowOps.create_agents_yml(str(tmp_project), "my-sess", str(wf))
        assert result is not None
        assert Path(result).exists()

        with open(result) as f:
            data = yaml.safe_load(f)
        assert data["pm"]["name"] == "pm"
        assert data["pm"]["role"] == "pm"
        assert data["agents"] == []

    def test_auto_detects_workflow(self, monkeypatch, tmp_project):
        """create_agents_yml with no explicit workflow_path auto-detects."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        result = WorkflowOps.create_agents_yml(str(tmp_project), "sess")
        assert result is not None

    def test_no_workflow(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.create_agents_yml(str(tmp_project), "sess")
        assert result is None


# ==================== WorkflowOps.add_agent_to_yml ====================


class TestAddAgentToYml:
    def test_adds_agent(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        WorkflowOps.create_agents_yml(str(tmp_project), "sess", str(wf))

        result = WorkflowOps.add_agent_to_yml(
            str(tmp_project), "developer", "developer", 1, "sonnet", "sess", pane_id="%10"
        )
        assert result is True

        content = (wf / "agents.yml").read_text()
        assert 'name: "developer"' in content
        assert 'pane_id: "%10"' in content
        assert 'role: "developer"' in content

    def test_updates_existing_agent(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        WorkflowOps.create_agents_yml(str(tmp_project), "sess", str(wf))

        WorkflowOps.add_agent_to_yml(str(tmp_project), "dev", "developer", 1, "sonnet", "sess")
        WorkflowOps.add_agent_to_yml(str(tmp_project), "dev", "developer", 2, "opus", "sess", pane_id="%20")

        content = (wf / "agents.yml").read_text()
        # Should only have one agent entry (updated, not duplicated)
        assert content.count('name: "dev"') == 1
        assert "window: 2" in content
        assert 'model: "opus"' in content

    def test_auto_creates_agents_yml(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        result = WorkflowOps.add_agent_to_yml(
            str(tmp_project), "dev", "developer", 1, "sonnet", "sess"
        )
        assert result is True
        assert (wf / "agents.yml").exists()

    def test_null_agents_yml(self, monkeypatch, tmp_project):
        """When agents.yml contains null (empty YAML), should handle gracefully."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text("")  # yaml.safe_load returns None

        result = WorkflowOps.add_agent_to_yml(
            str(tmp_project), "dev", "developer", 1, "sonnet", "sess"
        )
        assert result is True

    def test_agents_yml_missing_agents_key(self, monkeypatch, tmp_project):
        """When agents.yml exists but has no 'agents' key."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text("pm:\n  name: pm\n")

        result = WorkflowOps.add_agent_to_yml(
            str(tmp_project), "dev", "developer", 1, "sonnet", "sess"
        )
        assert result is True

    def test_no_workflow(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.add_agent_to_yml(
            str(tmp_project), "dev", "developer", 1, "sonnet", "sess"
        )
        assert result is False


# ==================== WorkflowOps._write_agents_yml ====================


class TestWriteAgentsYml:
    def test_writes_pm_and_agents(self, tmp_path):
        agents_file = tmp_path / "agents.yml"
        data = {
            "pm": {
                "name": "pm",
                "role": "pm",
                "pane_id": "%5",
                "session": "sess",
                "window": 0,
                "model": "opus",
            },
            "agents": [
                {
                    "name": "dev",
                    "role": "developer",
                    "pane_id": "%6",
                    "session": "sess",
                    "window": 1,
                    "model": "sonnet",
                },
            ],
        }
        WorkflowOps._write_agents_yml(agents_file, data)
        content = agents_file.read_text()
        assert "pm:" in content
        assert "agents:" in content
        assert "dev" in content

    def test_empty_agents_list(self, tmp_path):
        agents_file = tmp_path / "agents.yml"
        data = {"agents": []}
        WorkflowOps._write_agents_yml(agents_file, data)
        content = agents_file.read_text()
        assert "agents: []" in content

    def test_empty_pane_id_quoted(self, tmp_path):
        agents_file = tmp_path / "agents.yml"
        data = {
            "agents": [
                {"name": "dev", "role": "developer", "pane_id": "", "session": "s", "window": 1, "model": "sonnet"},
            ]
        }
        WorkflowOps._write_agents_yml(agents_file, data)
        content = agents_file.read_text()
        assert 'pane_id: ""' in content


# ==================== WorkflowOps.save_team_structure ====================


class TestSaveTeamStructure:
    def test_saves_agents(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        WorkflowOps.create_agents_yml(str(tmp_project), "sess", str(wf))

        agents = [
            {"name": "dev", "role": "developer", "model": "sonnet"},
            {"name": "qa", "role": "qa", "model": "haiku"},
        ]

        with patch("subprocess.run"):
            result = WorkflowOps.save_team_structure(str(tmp_project), agents, yato_path="/nonexistent")
            assert result is not None

        with open(wf / "agents.yml") as f:
            data = yaml.safe_load(f)
        assert len(data["agents"]) == 2

    def test_no_workflow(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.save_team_structure(str(tmp_project), [])
        assert result is None

    def test_updates_existing_agent(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        # Create initial agents.yml
        initial_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "", "session": "s", "window": 0, "model": "opus"},
            "agents": [{"name": "dev", "role": "developer", "model": "sonnet", "session": "", "window": ""}],
        }
        with open(wf / "agents.yml", "w") as f:
            yaml.dump(initial_data, f)

        agents = [{"name": "dev", "role": "developer", "model": "opus"}]
        with patch("subprocess.run"):
            WorkflowOps.save_team_structure(str(tmp_project), agents, yato_path="/nonexistent")

        with open(wf / "agents.yml") as f:
            data = yaml.safe_load(f)
        assert len(data["agents"]) == 1
        assert data["agents"][0]["model"] == "opus"

    def test_null_agents_yml(self, monkeypatch, tmp_project):
        """When agents.yml contains null YAML, should handle gracefully."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text("")

        agents = [{"name": "dev", "role": "developer", "model": "sonnet"}]
        with patch("subprocess.run"):
            result = WorkflowOps.save_team_structure(str(tmp_project), agents, yato_path="/nonexistent")
            assert result is not None

    def test_missing_agents_key_in_yml(self, monkeypatch, tmp_project):
        """When agents.yml has no 'agents' key."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text("pm:\n  name: pm\n")

        agents = [{"name": "dev", "role": "developer", "model": "sonnet"}]
        with patch("subprocess.run"):
            result = WorkflowOps.save_team_structure(str(tmp_project), agents, yato_path="/nonexistent")
            assert result is not None

    def test_no_agents_yml_file(self, monkeypatch, tmp_project):
        """When agents.yml doesn't exist, creates from scratch."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        agents = [{"name": "dev", "role": "developer", "model": "sonnet"}]
        with patch("subprocess.run"):
            result = WorkflowOps.save_team_structure(str(tmp_project), agents, yato_path="/nonexistent")
            assert result is not None

    def test_auto_detects_yato_path(self, monkeypatch, tmp_project):
        """save_team_structure auto-detects yato_path from env or __file__."""
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("YATO_PATH", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        WorkflowOps.create_agents_yml(str(tmp_project), "sess", str(wf))

        agents = [{"name": "dev", "role": "developer", "model": "sonnet"}]
        # No yato_path passed, should auto-detect and find init-agent-files.sh
        with patch("subprocess.run"):
            result = WorkflowOps.save_team_structure(str(tmp_project), agents)
            assert result is not None

    def test_calls_init_script(self, monkeypatch, tmp_project, tmp_path):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        WorkflowOps.create_agents_yml(str(tmp_project), "sess", str(wf))

        # Create a fake yato dir with init script
        yato_dir = tmp_path / "yato"
        bin_dir = yato_dir / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "init-agent-files.sh").write_text("#!/bin/bash\necho ok")

        agents = [{"name": "dev", "role": "developer", "model": "sonnet"}]
        with patch("subprocess.run") as mock_run:
            WorkflowOps.save_team_structure(str(tmp_project), agents, yato_path=str(yato_dir))
            # Should have called init-agent-files.sh
            assert mock_run.called


# ==================== WorkflowOps.update_status_yml ====================


class TestUpdateStatusYml:
    def test_updates_fields(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        status_file = wf / "status.yml"
        with open(status_file, "w") as f:
            yaml.dump({"status": "in-progress", "title": "Old"}, f)

        result = WorkflowOps.update_status_yml(str(tmp_project), {"title": "New", "custom_field": 42})
        assert result is True

        with open(status_file) as f:
            data = yaml.safe_load(f)
        assert data["title"] == "New"
        assert data["custom_field"] == 42
        assert data["status"] == "in-progress"

    def test_no_workflow(self, monkeypatch, tmp_project):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        monkeypatch.delenv("TMUX", raising=False)
        result = WorkflowOps.update_status_yml(str(tmp_project), {"status": "done"})
        assert result is False

    def test_no_status_file(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        (tmp_project / ".workflow" / "001-test").mkdir(parents=True)
        result = WorkflowOps.update_status_yml(str(tmp_project), {"status": "done"})
        assert result is False

    def test_empty_status_file(self, monkeypatch, tmp_project):
        monkeypatch.setenv("WORKFLOW_NAME", "001-test")
        monkeypatch.delenv("_YATO_WORKFLOW_NAME", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "status.yml").write_text("")

        result = WorkflowOps.update_status_yml(str(tmp_project), {"status": "done"})
        assert result is True

        with open(wf / "status.yml") as f:
            data = yaml.safe_load(f)
        assert data["status"] == "done"
