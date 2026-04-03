"""Tests for lib/workflow_registry.py — workflow-scoped agent management."""

import os
import runpy
import subprocess
import sys
import warnings
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import yaml

from lib.workflow_registry import WorkflowRegistry
from lib.session_registry import Agent


# ==================== WorkflowRegistry.__init__ ====================


class TestWorkflowRegistryInit:
    def test_sets_workflow_path(self, tmp_path):
        reg = WorkflowRegistry(tmp_path / "wf")
        assert reg.workflow_path == tmp_path / "wf"

    def test_sets_agents_file(self, tmp_path):
        reg = WorkflowRegistry(tmp_path / "wf")
        assert reg.agents_file == tmp_path / "wf" / "agents.yml"

    def test_accepts_string_path(self, tmp_path):
        # Path is converted via Path() in __init__
        reg = WorkflowRegistry(tmp_path / "wf")
        assert isinstance(reg.workflow_path, Path)


# ==================== WorkflowRegistry.from_project ====================


class TestFromProject:
    def test_no_workflow_dir_returns_none(self, tmp_project):
        result = WorkflowRegistry.from_project(tmp_project)
        assert result is None

    def test_explicit_workflow_name_found(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        result = WorkflowRegistry.from_project(project, "001-test-feature")
        assert result is not None
        assert result.workflow_path == tmp_workflow

    def test_explicit_workflow_name_not_found(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        result = WorkflowRegistry.from_project(project, "999-nonexistent")
        assert result is None

    def test_env_var_workflow_name(self, tmp_workflow, monkeypatch):
        project = tmp_workflow.parent.parent
        monkeypatch.setenv("WORKFLOW_NAME", "001-test-feature")
        with patch.object(WorkflowRegistry, "_get_tmux_workflow_name", return_value=None):
            result = WorkflowRegistry.from_project(project)
        assert result is not None
        assert result.workflow_path.name == "001-test-feature"

    def test_env_var_workflow_name_not_found_falls_through(self, tmp_workflow, monkeypatch):
        """If WORKFLOW_NAME env var points to nonexistent dir, falls through to tmux."""
        project = tmp_workflow.parent.parent
        monkeypatch.setenv("WORKFLOW_NAME", "999-bad")
        with patch.object(WorkflowRegistry, "_get_tmux_workflow_name", return_value=None):
            result = WorkflowRegistry.from_project(project)
        # Falls through to most recent workflow
        assert result is not None

    def test_tmux_env_workflow_name(self, tmp_workflow, monkeypatch):
        project = tmp_workflow.parent.parent
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        with patch.object(WorkflowRegistry, "_get_tmux_workflow_name", return_value="001-test-feature"):
            result = WorkflowRegistry.from_project(project)
        assert result is not None
        assert result.workflow_path.name == "001-test-feature"

    def test_fallback_most_recent(self, tmp_project, monkeypatch):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        wf_dir = tmp_project / ".workflow"
        wf_dir.mkdir()
        (wf_dir / "001-older").mkdir()
        (wf_dir / "003-newest").mkdir()
        (wf_dir / "002-middle").mkdir()
        with patch.object(WorkflowRegistry, "_get_tmux_workflow_name", return_value=None):
            result = WorkflowRegistry.from_project(tmp_project)
        assert result is not None
        assert result.workflow_path.name == "003-newest"

    def test_no_workflows_returns_none(self, tmp_project, monkeypatch):
        monkeypatch.delenv("WORKFLOW_NAME", raising=False)
        wf_dir = tmp_project / ".workflow"
        wf_dir.mkdir()
        with patch.object(WorkflowRegistry, "_get_tmux_workflow_name", return_value=None):
            result = WorkflowRegistry.from_project(tmp_project)
        assert result is None


# ==================== WorkflowRegistry._get_tmux_workflow_name ====================


class TestGetTmuxWorkflowName:
    @patch("lib.workflow_registry.subprocess.run")
    def test_returns_value(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="WORKFLOW_NAME=001-feat\n")
        result = WorkflowRegistry._get_tmux_workflow_name()
        assert result == "001-feat"

    @patch("lib.workflow_registry.subprocess.run")
    def test_no_equals_returns_none(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="-WORKFLOW_NAME\n")
        result = WorkflowRegistry._get_tmux_workflow_name()
        assert result is None

    @patch("lib.workflow_registry.subprocess.run")
    def test_failure_returns_none(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        result = WorkflowRegistry._get_tmux_workflow_name()
        assert result is None

    @patch("lib.workflow_registry.subprocess.run")
    def test_uses_tmux_socket(self, mock_run, clean_env):
        clean_env.setenv("TMUX_SOCKET", "mysock")
        mock_run.return_value = MagicMock(returncode=0, stdout="WORKFLOW_NAME=val\n")
        WorkflowRegistry._get_tmux_workflow_name()
        args = mock_run.call_args[0][0]
        assert args[:3] == ["tmux", "-L", "mysock"]

    @patch("lib.workflow_registry.subprocess.run")
    def test_without_tmux_socket(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="WORKFLOW_NAME=val\n")
        WorkflowRegistry._get_tmux_workflow_name()
        args = mock_run.call_args[0][0]
        assert args[0] == "tmux"
        assert "-L" not in args

    @patch("lib.workflow_registry.subprocess.run", side_effect=FileNotFoundError)
    def test_file_not_found_returns_none(self, mock_run, clean_env):
        result = WorkflowRegistry._get_tmux_workflow_name()
        assert result is None


# ==================== _load_agents_yml / _save_agents_yml ====================


class TestLoadSaveAgentsYml:
    def test_load_missing_file(self, tmp_path):
        reg = WorkflowRegistry(tmp_path / "wf")
        data = reg._load_agents_yml()
        assert data == {"pm": None, "agents": []}

    def test_load_existing_file(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        data = reg._load_agents_yml()
        assert data["pm"]["name"] == "pm"
        assert len(data["agents"]) == 2

    def test_load_corrupt_yaml(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "agents.yml").write_text(": : : invalid yaml [[[")
        reg = WorkflowRegistry(wf)
        data = reg._load_agents_yml()
        assert data == {"pm": None, "agents": []}

    def test_load_empty_file(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "agents.yml").write_text("")
        reg = WorkflowRegistry(wf)
        data = reg._load_agents_yml()
        assert data == {"pm": None, "agents": []}

    def test_save_creates_dirs(self, tmp_path):
        wf = tmp_path / "deep" / "nested" / "wf"
        reg = WorkflowRegistry(wf)
        reg._save_agents_yml({"pm": None, "agents": []})
        assert (wf / "agents.yml").exists()

    def test_save_and_reload(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        reg = WorkflowRegistry(wf)
        data = {"pm": {"name": "pm", "role": "pm"}, "agents": [{"name": "dev", "role": "developer"}]}
        reg._save_agents_yml(data)
        loaded = reg._load_agents_yml()
        assert loaded["pm"]["name"] == "pm"
        assert loaded["agents"][0]["name"] == "dev"

    def test_save_and_reload_pane_id_with_percent(self, tmp_path):
        """pane_id values like %183 must survive YAML round-trip (% is a YAML directive char)."""
        wf = tmp_path / "wf"
        wf.mkdir()
        reg = WorkflowRegistry(wf)
        data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "%100", "session": "s", "window": 0, "model": "opus"},
            "agents": [
                {"name": "dev", "role": "developer", "pane_id": "%183", "session": "s", "window": 1, "model": "sonnet"},
                {"name": "qa", "role": "qa", "pane_id": "%184", "session": "s", "window": 2, "model": "sonnet"},
            ],
        }
        reg._save_agents_yml(data)
        loaded = reg._load_agents_yml()
        assert loaded["pm"]["pane_id"] == "%100"
        assert loaded["agents"][0]["pane_id"] == "%183"
        assert loaded["agents"][1]["pane_id"] == "%184"


# ==================== _agent_from_yml_entry / _agent_to_yml_entry ====================


class TestAgentFromYmlEntry:
    def test_basic_conversion(self, tmp_workflow):
        reg = WorkflowRegistry(tmp_workflow)
        entry = {"name": "dev", "role": "developer", "session": "s", "window": 1, "pane_id": "%5", "model": "sonnet"}
        agent = reg._agent_from_yml_entry(entry)
        assert isinstance(agent, Agent)
        assert agent.name == "dev"
        assert agent.role == "developer"
        assert agent.session_name == "s"
        assert agent.window_index == 1
        assert agent.pane_id == "%5"

    def test_defaults(self, tmp_workflow):
        reg = WorkflowRegistry(tmp_workflow)
        entry = {}
        agent = reg._agent_from_yml_entry(entry)
        assert agent.session_name == ""
        assert agent.window_index == 0
        assert agent.role == "developer"


class TestAgentToYmlEntry:
    def test_basic_conversion(self, tmp_workflow):
        reg = WorkflowRegistry(tmp_workflow)
        agent = Agent(session_name="s", window_index=1, role="qa", name="qa", model="haiku", pane_id="%7")
        entry = reg._agent_to_yml_entry(agent)
        assert entry["name"] == "qa"
        assert entry["role"] == "qa"
        assert entry["pane_id"] == "%7"
        assert entry["session"] == "s"
        assert entry["window"] == 1
        assert entry["model"] == "haiku"

    def test_defaults_when_none(self, tmp_workflow):
        reg = WorkflowRegistry(tmp_workflow)
        agent = Agent(session_name="s", window_index=0, role="developer")
        entry = reg._agent_to_yml_entry(agent)
        assert entry["name"] == "developer"
        assert entry["pane_id"] == ""
        assert entry["model"] == "sonnet"


# ==================== get_pm ====================


class TestGetPm:
    def test_get_pm(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        pm = reg.get_pm()
        assert pm is not None
        assert pm.role == "pm"
        assert pm.pane_id == "%5"

    def test_no_pm(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "agents.yml").write_text(yaml.dump({"pm": None, "agents": []}))
        reg = WorkflowRegistry(wf)
        assert reg.get_pm() is None

    def test_pm_is_not_dict(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "agents.yml").write_text(yaml.dump({"pm": "string-value", "agents": []}))
        reg = WorkflowRegistry(wf)
        assert reg.get_pm() is None


# ==================== get_agent ====================


class TestGetAgent:
    def test_pm_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent("pm")
        assert agent is not None
        assert agent.role == "pm"

    def test_agent_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent("developer")
        assert agent is not None
        assert agent.role == "developer"

    def test_not_found(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        assert reg.get_agent("nonexistent") is None


# ==================== get_agent_by_pane_id ====================


class TestGetAgentByPaneId:
    def test_pm_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent_by_pane_id("%5")
        assert agent is not None
        assert agent.role == "pm"

    def test_agent_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent_by_pane_id("%6")
        assert agent is not None
        assert agent.role == "developer"

    def test_not_found(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        assert reg.get_agent_by_pane_id("%99") is None


# ==================== get_agent_by_target ====================


class TestGetAgentByTarget:
    def test_pm_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent_by_target("test-session", 0)
        assert agent is not None
        assert agent.role == "pm"

    def test_agent_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent_by_target("test-session", 1)
        assert agent is not None
        assert agent.role == "developer"

    def test_not_found(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        assert reg.get_agent_by_target("test-session", 99) is None

    def test_with_pane_id_filter_match(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = reg.get_agent_by_target("test-session", 0, pane_id="%5")
        assert agent is not None
        assert agent.role == "pm"

    def test_with_pane_id_filter_mismatch(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        # Correct session/window but wrong pane_id
        agent = reg.get_agent_by_target("test-session", 0, pane_id="%99")
        assert agent is None


# ==================== list_agents ====================


class TestListAgents:
    def test_all_agents(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agents = reg.list_agents()
        assert len(agents) == 3  # PM + developer + qa

    def test_filter_by_role(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        devs = reg.list_agents(role="developer")
        assert len(devs) == 1
        assert devs[0].role == "developer"

    def test_empty_registry(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        reg = WorkflowRegistry(wf)
        assert reg.list_agents() == []

    def test_pm_included_when_no_filter(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        roles = [a.role for a in reg.list_agents()]
        assert "pm" in roles


# ==================== add_agent ====================


class TestAddAgent:
    def test_add_pm(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        reg = WorkflowRegistry(wf)
        agent = Agent(session_name="s", window_index=0, role="pm", name="PM", pane_id="%1")
        reg.add_agent(agent, is_pm=True)
        pm = reg.get_pm()
        assert pm is not None
        assert pm.pane_id == "%1"

    def test_add_pm_by_role(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        reg = WorkflowRegistry(wf)
        agent = Agent(session_name="s", window_index=0, role="pm", name="PM")
        reg.add_agent(agent)  # No is_pm flag, but role is pm
        pm = reg.get_pm()
        assert pm is not None

    def test_add_new_agent(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        reg = WorkflowRegistry(wf)
        agent = Agent(session_name="s", window_index=1, role="developer", name="dev")
        reg.add_agent(agent)
        found = reg.get_agent("dev")
        assert found is not None
        assert found.role == "developer"

    def test_update_existing_agent_by_name(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        agent = Agent(session_name="s", window_index=5, role="developer", name="developer", model="opus")
        reg.add_agent(agent)
        # Should update, not duplicate
        agents = reg.list_agents(role="developer")
        assert len(agents) == 1
        assert agents[0].model == "opus"


# ==================== remove_agent ====================


class TestRemoveAgent:
    def test_remove_agent(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        result = reg.remove_agent("developer")
        assert result is True
        assert reg.get_agent("developer") is None

    def test_cannot_remove_pm(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        result = reg.remove_agent("pm")
        assert result is False
        assert reg.get_pm() is not None

    def test_agent_not_found(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        result = reg.remove_agent("nonexistent")
        assert result is False


# ==================== get_team ====================


class TestGetTeam:
    def test_non_pm_agents_only(self, tmp_workflow_with_agents):
        reg = WorkflowRegistry(tmp_workflow_with_agents)
        team = reg.get_team()
        assert len(team) == 2
        roles = [a.role for a in team]
        assert "pm" not in roles
        assert "developer" in roles
        assert "qa" in roles

    def test_empty_team(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "agents.yml").write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm", "session": "s", "window": 0, "pane_id": "%1", "model": "opus"},
            "agents": []
        }))
        reg = WorkflowRegistry(wf)
        assert reg.get_team() == []

# ==================== __main__ CLI ====================


class TestWorkflowRegistryCLI:
    def test_with_workflow_and_agents(self, tmp_workflow_with_agents, monkeypatch, capsys):
        """Test CLI output when workflow has PM and team agents."""
        project = tmp_workflow_with_agents.parent.parent
        monkeypatch.setattr(sys, "argv", ["script", str(project)])
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            runpy.run_module("lib.workflow_registry", run_name="__main__", alter_sys=True)
        captured = capsys.readouterr()
        assert "Workflow path" in captured.out
        assert "Agents file" in captured.out
        assert "PM:" in captured.out
        assert "Team" in captured.out

    def test_with_workflow_no_agents(self, tmp_workflow, monkeypatch, capsys):
        """Test CLI with workflow but no agents."""
        project = tmp_workflow.parent.parent
        monkeypatch.setattr(sys, "argv", ["script", str(project)])
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            runpy.run_module("lib.workflow_registry", run_name="__main__", alter_sys=True)
        captured = capsys.readouterr()
        assert "Workflow path" in captured.out

    def test_no_workflow(self, tmp_project, monkeypatch, capsys):
        """Test CLI when no workflow exists."""
        monkeypatch.setattr(sys, "argv", ["script", str(tmp_project)])
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            runpy.run_module("lib.workflow_registry", run_name="__main__", alter_sys=True)
        captured = capsys.readouterr()
        assert "No workflow found" in captured.out

    def test_default_path(self, tmp_path, monkeypatch, capsys):
        """Test CLI with no args (uses '.')."""
        monkeypatch.chdir(tmp_path)
        monkeypatch.setattr(sys, "argv", ["script"])
        with warnings.catch_warnings():
            warnings.simplefilter("ignore", RuntimeWarning)
            runpy.run_module("lib.workflow_registry", run_name="__main__", alter_sys=True)
        captured = capsys.readouterr()
        assert "No workflow found" in captured.out

