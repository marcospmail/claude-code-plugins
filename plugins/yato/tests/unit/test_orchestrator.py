"""Tests for lib/orchestrator.py — main orchestration entry point."""

import json
import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch, call, PropertyMock

import pytest
import yaml

from lib.orchestrator import Orchestrator
from lib.session_registry import Agent
from lib.tmux_utils import TmuxOrchestrator as TmuxUtils
from lib.workflow_registry import WorkflowRegistry

import argparse
from lib.orchestrator import cmd_init, cmd_status, cmd_deploy, cmd_start, cmd_brief, cmd_check, cmd_deploy_pm, main


# ==================== Orchestrator.__init__ ====================


class TestOrchestratorInit:
    def test_defaults(self):
        orc = Orchestrator()
        assert orc.project_root is not None
        assert orc.tmux is not None
        assert orc.tmux.safety_mode is False

    def test_custom_paths(self, tmp_path):
        orc = Orchestrator(project_root=tmp_path, project_path=str(tmp_path / "proj"))
        assert orc.project_root == tmp_path
        assert orc._project_path is not None

    def test_workflow_name(self):
        orc = Orchestrator(workflow_name="001-test")
        assert orc._workflow_name == "001-test"


# ==================== _get_registry ====================


class TestGetRegistry:
    @patch.object(WorkflowRegistry, "from_project", return_value=MagicMock())
    def test_with_project_path(self, mock_fp, tmp_workflow):
        project = tmp_workflow.parent.parent
        orc = Orchestrator(project_path=str(project))
        reg = orc._get_registry()
        assert reg is not None

    def test_without_project_path(self):
        orc = Orchestrator()
        reg = orc._get_registry()
        assert reg is None

    @patch.object(WorkflowRegistry, "from_project", return_value=MagicMock())
    def test_explicit_project_path_override(self, mock_fp, tmp_workflow):
        project = tmp_workflow.parent.parent
        orc = Orchestrator()
        reg = orc._get_registry(str(project))
        assert reg is not None


# ==================== _register_agent_to_workflow ====================


class TestRegisterAgentToWorkflow:
    def test_success(self, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        agent = orc._register_agent_to_workflow(
            project_path=str(project),
            session_name="sess",
            window_index=3,
            role="developer",
            name="dev2",
            model="sonnet",
            pane_id="%20",
        )
        assert agent is not None
        assert agent.role == "developer"
        assert agent.pane_id == "%20"

    def test_no_registry_returns_none(self):
        orc = Orchestrator()
        result = orc._register_agent_to_workflow(
            project_path="/nonexistent",
            session_name="sess",
            window_index=0,
            role="pm",
        )
        assert result is None


# ==================== create_project_session ====================


class TestCreateProjectSession:
    @patch.object(TmuxUtils, "create_window")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_with_pm_and_developer(self, mock_exists, mock_create, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        result = orc.create_project_session("sess", str(project))
        assert "error" not in result
        assert len(result["agents"]) == 2
        assert mock_window.call_count == 2

    @patch.object(TmuxUtils, "create_window")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_without_pm(self, mock_exists, mock_create, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        result = orc.create_project_session("sess", str(project), with_pm=False)
        assert len(result["agents"]) == 1

    @patch.object(TmuxUtils, "create_window")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_without_developer(self, mock_exists, mock_create, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        result = orc.create_project_session("sess", str(project), with_developer=False)
        assert len(result["agents"]) == 1

    @patch.object(TmuxUtils, "session_exists", return_value=True)
    @patch.object(TmuxUtils, "create_window")
    def test_session_already_exists(self, mock_window, mock_exists, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        result = orc.create_project_session("sess", str(project))
        assert "error" not in result

    @patch.object(TmuxUtils, "create_session", return_value=False)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_failed_session_creation(self, mock_exists, mock_create, tmp_path):
        orc = Orchestrator()
        result = orc.create_project_session("sess", str(tmp_path))
        assert "error" in result

    def test_creates_directory_if_missing(self, tmp_path):
        project_dir = tmp_path / "new_project"
        orc = Orchestrator()
        with patch.object(TmuxUtils, "session_exists", return_value=True), \
             patch.object(TmuxUtils, "create_window", return_value=None):
            result = orc.create_project_session("sess", str(project_dir))
        assert result["directory_created"] is True
        assert project_dir.exists()


# ==================== deploy_team ====================


class TestDeployTeam:
    @patch.object(TmuxUtils, "create_window")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_windows_mode(self, mock_exists, mock_create, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        team_config = [
            {"role": "pm"},
            {"role": "developer"},
        ]
        result = orc.deploy_team("sess", str(project), team_config)
        assert "error" not in result
        assert len(result["agents"]) == 2

    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "set_pane_title")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_panes_mode(self, mock_exists, mock_create, mock_title, mock_run, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_run.return_value = MagicMock(returncode=0, stdout="%10\n")
        orc = Orchestrator(project_path=str(project))
        team_config = [
            {"role": "pm"},
            {"role": "developer"},
        ]
        result = orc.deploy_team("sess", str(project), team_config, use_panes=True)
        assert "error" not in result
        assert result["use_panes"] is True

    @patch.object(TmuxUtils, "create_session", return_value=False)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_session_creation_failure(self, mock_exists, mock_create, tmp_path):
        orc = Orchestrator()
        result = orc.deploy_team("sess", str(tmp_path), [{"role": "pm"}])
        assert "error" in result

    def test_creates_directory(self, tmp_path):
        project_dir = tmp_path / "new_proj"
        orc = Orchestrator()
        with patch.object(TmuxUtils, "session_exists", return_value=True), \
             patch.object(TmuxUtils, "create_window", return_value={"window_index": 1, "pane_id": "%1"}):
            result = orc.deploy_team("sess", str(project_dir), [{"role": "developer"}])
        assert result["directory_created"] is True


# ==================== deploy_pm_only ====================


class TestDeployPmOnly:
    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_creates_session_and_pm(self, mock_exists, mock_create, mock_run, mock_sleep, tmp_workflow):
        project = tmp_workflow.parent.parent
        mock_run.return_value = MagicMock(returncode=0, stdout="%5\n")
        orc = Orchestrator(project_path=str(project))
        result = orc.deploy_pm_only("sess", str(project), "001-test-feature")
        assert "error" not in result
        assert result["pm_target"] is not None
        assert len(result["agents"]) >= 1

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "create_session", return_value=False)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_session_creation_failure(self, mock_exists, mock_create, mock_run, mock_sleep, tmp_path):
        orc = Orchestrator()
        result = orc.deploy_pm_only("sess", str(tmp_path))
        assert "error" in result


# ==================== start_pm_with_planning_briefing ====================


class TestStartPmWithPlanningBriefing:
    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "send_message")
    def test_sends_claude_command_and_briefing(self, mock_send, mock_run, mock_sleep):
        mock_run.return_value = MagicMock(returncode=0)
        orc = Orchestrator(workflow_name="001-test")
        result = orc.start_pm_with_planning_briefing("%5", "/tmp/proj")
        assert result is True
        # Should send claude command
        mock_run.assert_called_once()
        cmd_args = mock_run.call_args[0][0]
        assert any("claude" in str(a) for a in cmd_args)
        # Should send briefing with skip_suffix=True (system briefing, no appended suffixes)
        mock_send.assert_called_once()
        call_kwargs = mock_send.call_args
        assert call_kwargs[1]["_skip_suffix"] is True

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "send_message")
    def test_briefing_skips_suffix(self, mock_send, mock_run, mock_sleep):
        """The initial briefing to PM must not include message suffixes."""
        mock_run.return_value = MagicMock(returncode=0)
        orc = Orchestrator(workflow_name="001-test")
        orc.start_pm_with_planning_briefing("%5", "/tmp/proj")
        mock_send.assert_called_once()
        # Verify _skip_suffix is True and target is the PM pane
        args, kwargs = mock_send.call_args
        assert args[0] == "%5"  # pm_target passed through
        assert kwargs["_skip_suffix"] is True


# ==================== _deploy_team_windows ====================


class TestDeployTeamWindows:
    @patch.object(TmuxUtils, "create_window")
    def test_pm_first_then_others(self, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        result = {"agents": [], "session": "sess"}
        team = [
            {"role": "developer", "name": "Dev"},
            {"role": "pm", "name": "PM"},  # PM not first in list
            {"role": "qa", "name": "QA"},
        ]
        orc._deploy_team_windows("sess", str(project), team, result)
        # PM should be created first (it's found and processed before others)
        roles = [a["role"] for a in result["agents"]]
        assert roles[0] == "pm"
        assert "developer" in roles
        assert "qa" in roles


# ==================== _deploy_team_panes ====================


class TestDeployTeamPanes:
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "set_pane_title")
    def test_layout_with_splits(self, mock_title, mock_run, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_run.return_value = MagicMock(returncode=0, stdout="%10\n")
        orc = Orchestrator(project_path=str(project))
        result = {"agents": [], "session": "sess"}
        team = [
            {"role": "pm"},
            {"role": "developer"},
            {"role": "qa"},
        ]
        orc._deploy_team_panes("sess", str(project), team, result)
        # Should set pane titles
        assert mock_title.call_count >= 1


# ==================== _get_default_model ====================


class TestGetDefaultModel:
    def test_pm(self):
        orc = Orchestrator()
        assert orc._get_default_model("pm") == "sonnet"

    def test_developer(self):
        orc = Orchestrator()
        assert orc._get_default_model("developer") == "sonnet"

    def test_qa(self):
        orc = Orchestrator()
        assert orc._get_default_model("qa") == "haiku"

    def test_architect(self):
        orc = Orchestrator()
        assert orc._get_default_model("architect") == "opus"

    def test_unknown_defaults_to_sonnet(self):
        orc = Orchestrator()
        assert orc._get_default_model("unknown") == "sonnet"


# ==================== start_claude_in_agents ====================


class TestStartClaudeInAgents:
    @patch.object(TmuxUtils, "send_message_to_agent", return_value=True)
    def test_all_agents(self, mock_send, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        results = orc.start_claude_in_agents(str(project))
        assert len(results) > 0
        assert all(v is True for v in results.values())

    @patch.object(TmuxUtils, "send_message_to_agent", return_value=True)
    def test_specific_agents(self, mock_send, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        results = orc.start_claude_in_agents(str(project), agent_ids=["developer"])
        # Should only start the developer agent
        assert len(results) == 1

    def test_no_registry(self):
        orc = Orchestrator()
        results = orc.start_claude_in_agents("/nonexistent")
        assert results == {}


# ==================== brief_agent ====================


class TestBriefAgent:
    @patch.object(TmuxUtils, "send_message_to_agent", return_value=True)
    def test_delegates_to_tmux(self, mock_send):
        orc = Orchestrator()
        result = orc.brief_agent("%5", "Hello agent")
        assert result is True
        mock_send.assert_called_once_with("%5", "Hello agent")


# ==================== brief_team ====================


class TestBriefTeam:
    @patch.object(TmuxUtils, "send_message_to_agent", return_value=True)
    def test_sends_to_all_non_pm(self, mock_send, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        results = orc.brief_team(str(project), "Team message")
        # Should send to developer and qa, not PM
        assert len(results) == 2
        assert all(v is True for v in results.values())

    def test_no_registry(self):
        orc = Orchestrator()
        results = orc.brief_team("/nonexistent", "msg")
        assert results == {}


# ==================== check_agent_status ====================


class TestCheckAgentStatus:
    @patch.object(TmuxUtils, "capture_agent_output", return_value="agent output here")
    def test_captures_output(self, mock_capture):
        orc = Orchestrator()
        result = orc.check_agent_status("%5", 30)
        assert result == "agent output here"
        mock_capture.assert_called_once_with("%5", 30)


# ==================== get_system_status ====================


class TestGetSystemStatus:
    @patch.object(TmuxUtils, "get_all_windows_status", return_value=[])
    def test_without_project_path(self, mock_status):
        orc = Orchestrator()
        status = orc.get_system_status()
        assert "timestamp" in status
        assert "sessions" in status
        assert "agents" in status

    @patch.object(TmuxUtils, "get_all_windows_status", return_value=[])
    def test_with_project_path(self, mock_status, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        status = orc.get_system_status(str(project))
        assert "workflow" in status
        assert len(status["agents"]) > 0


# ==================== create_snapshot ====================


class TestCreateSnapshot:
    @patch.object(TmuxUtils, "create_monitoring_snapshot", return_value="snapshot data")
    def test_delegates_to_tmux(self, mock_snapshot):
        orc = Orchestrator()
        result = orc.create_snapshot()
        assert result == "snapshot data"


# ==================== Edge cases and additional coverage ====================


class TestDeployTeamWindowsNoPM:
    """Test _deploy_team_windows when no PM in config."""

    @patch.object(TmuxUtils, "create_window")
    def test_no_pm_in_config(self, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_window.return_value = {"window_index": 1, "pane_id": "%10"}
        orc = Orchestrator(project_path=str(project))
        result = {"agents": [], "session": "sess"}
        team = [{"role": "developer", "name": "Dev"}]
        orc._deploy_team_windows("sess", str(project), team, result)
        assert len(result["agents"]) == 1
        assert result["agents"][0]["role"] == "developer"


class TestDeployTeamPanesNoOtherAgents:
    """Test _deploy_team_panes with only PM."""

    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "set_pane_title")
    def test_pm_only_no_splits(self, mock_title, mock_run, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_run.return_value = MagicMock(returncode=0, stdout="%10\n")
        orc = Orchestrator(project_path=str(project))
        result = {"agents": [], "session": "sess"}
        team = [{"role": "pm"}]
        orc._deploy_team_panes("sess", str(project), team, result)
        assert len(result["agents"]) == 1
        assert result["agents"][0]["role"] == "pm"


class TestCreateProjectSessionWindowFails:
    """Test create_project_session when window creation fails."""

    @patch.object(TmuxUtils, "create_window", return_value=None)
    @patch.object(TmuxUtils, "session_exists", return_value=True)
    def test_window_creation_returns_none(self, mock_exists, mock_window, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        result = orc.create_project_session("sess", str(project))
        assert result["agents"] == []  # No agents created since windows failed


class TestStartClaudeInAgentsPartialFailure:
    """Test start_claude_in_agents when some sends fail."""

    @patch.object(TmuxUtils, "send_message_to_agent")
    def test_mixed_results(self, mock_send, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        mock_send.side_effect = [True, False, True]  # PM ok, dev fail, qa ok
        orc = Orchestrator(project_path=str(project))
        results = orc.start_claude_in_agents(str(project))
        assert len(results) == 3
        assert not all(results.values())

    @patch.object(TmuxUtils, "send_message_to_agent", return_value=True)
    def test_nonexistent_agent_id(self, mock_send, tmp_workflow_with_agents):
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))
        results = orc.start_claude_in_agents(str(project), agent_ids=["nonexistent"])
        assert results == {}


class TestBriefTeamEmpty:
    """Test brief_team when team has no members."""

    @patch.object(TmuxUtils, "send_message_to_agent")
    def test_empty_team(self, mock_send, tmp_path):
        wf = tmp_path / "project" / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm", "session": "s", "window": 0, "pane_id": "%1", "model": "opus"},
            "agents": [],
        }))
        project = tmp_path / "project"
        orc = Orchestrator(project_path=str(project))
        results = orc.brief_team(str(project), "msg")
        assert results == {}
        mock_send.assert_not_called()


# ==================== deploy_pm_only: directory creation (lines 262-263) ====================


class TestDeployPmOnlyCreatesDirectory:
    """Test deploy_pm_only creates project directory when it doesn't exist."""

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_creates_directory_when_missing(self, mock_exists, mock_create, mock_run, mock_sleep, tmp_path):
        project_dir = tmp_path / "nonexistent_project"
        assert not project_dir.exists()
        mock_run.return_value = MagicMock(returncode=0, stdout="%5\n")
        orc = Orchestrator()
        result = orc.deploy_pm_only("sess", str(project_dir), "001-test")
        assert result["directory_created"] is True
        assert project_dir.exists()


# ==================== deploy_pm_only: pm_identity.yml update (lines 361-365) ====================


class TestDeployPmOnlyUpdatesIdentity:
    """Test deploy_pm_only updates pm_identity.yml with pane_id."""

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_updates_identity_yml_with_pane_id(self, mock_exists, mock_create, mock_run, mock_sleep, tmp_path):
        project_dir = tmp_path / "project"
        wf_dir = project_dir / ".workflow" / "001-test" / "agents" / "pm"
        wf_dir.mkdir(parents=True)
        identity_content = "session: old\nwindow: 99\npane_id: \"%0\"\nrole: pm\n"
        (wf_dir / "identity.yml").write_text(identity_content)
        # Also create status.yml so the status update doesn't fail
        status_dir = project_dir / ".workflow" / "001-test"
        (status_dir / "status.yml").write_text('session: "old-session"\nstatus: planning\n')

        mock_run.return_value = MagicMock(returncode=0, stdout="%42\n")
        orc = Orchestrator(project_path=str(project_dir))
        result = orc.deploy_pm_only("mysess", str(project_dir), "001-test")

        assert "error" not in result
        updated = (wf_dir / "identity.yml").read_text()
        assert "0" in updated  # window updated to 0
        assert "%42" in updated  # pane_id updated

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "create_session", return_value=True)
    @patch.object(TmuxUtils, "session_exists", return_value=False)
    def test_updates_identity_without_pane_id_when_none(self, mock_exists, mock_create, mock_run, mock_sleep, tmp_path):
        """When pm_pane_id is None (returncode != 0), pane_id line is not updated."""
        project_dir = tmp_path / "project"
        wf_dir = project_dir / ".workflow" / "001-test" / "agents" / "pm"
        wf_dir.mkdir(parents=True)
        identity_content = "session: old\nwindow: 99\npane_id: \"%0\"\nrole: pm\n"
        (wf_dir / "identity.yml").write_text(identity_content)
        status_dir = project_dir / ".workflow" / "001-test"
        (status_dir / "status.yml").write_text('session: "old"\nstatus: planning\n')

        # Simulate pane_id capture failing (returncode != 0 for display-message)
        def run_side_effect(cmd, **kwargs):
            result = MagicMock(returncode=0, stdout="")
            # The display-message call to get PM pane_id
            if "display-message" in cmd:
                result.returncode = 1
                result.stdout = ""
            return result

        mock_run.side_effect = run_side_effect
        orc = Orchestrator(project_path=str(project_dir))
        result = orc.deploy_pm_only("mysess", str(project_dir), "001-test")

        assert "error" not in result
        updated = (wf_dir / "identity.yml").read_text()
        # window should still be updated to 0
        assert "window: 0" in updated
        # pane_id should remain the old value since pm_pane_id was None
        assert '"%0"' in updated


# ==================== start_pm_with_planning_briefing: wf_status (lines 412-414) ====================


class TestStartPmWithPlanningBriefingWfStatus:
    """Test that start_pm_with_planning_briefing passes wf_status file when exists."""

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "send_message")
    def test_passes_wf_status_file_when_exists(self, mock_send, mock_run, mock_sleep, tmp_path):
        project_dir = tmp_path / "project"
        wf_dir = project_dir / ".workflow" / "001-test"
        wf_dir.mkdir(parents=True)
        status_file = wf_dir / "status.yml"
        status_file.write_text("status: planning\n")

        mock_run.return_value = MagicMock(returncode=0)
        orc = Orchestrator(project_path=str(project_dir), workflow_name="001-test")
        orc.start_pm_with_planning_briefing("%5", str(project_dir))

        mock_send.assert_called_once()
        call_kwargs = mock_send.call_args
        assert call_kwargs[1]["workflow_status_file"] == str(status_file)

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "send_message")
    def test_passes_none_when_no_status_file(self, mock_send, mock_run, mock_sleep, tmp_path):
        """When status.yml doesn't exist, wf_status is None."""
        project_dir = tmp_path / "project"
        project_dir.mkdir(parents=True)

        mock_run.return_value = MagicMock(returncode=0)
        orc = Orchestrator(project_path=str(project_dir), workflow_name="001-nonexistent")
        orc.start_pm_with_planning_briefing("%5", str(project_dir))

        mock_send.assert_called_once()
        call_kwargs = mock_send.call_args
        assert call_kwargs[1]["workflow_status_file"] is None

    @patch("time.sleep")
    @patch("lib.orchestrator.subprocess.run")
    @patch.object(TmuxUtils, "send_message")
    def test_passes_none_when_no_project_path(self, mock_send, mock_run, mock_sleep):
        """When project_path is not set on orchestrator, wf_status is None."""
        mock_run.return_value = MagicMock(returncode=0)
        orc = Orchestrator(workflow_name="001-test")
        orc.start_pm_with_planning_briefing("%5", "/tmp/proj")

        mock_send.assert_called_once()
        call_kwargs = mock_send.call_args
        assert call_kwargs[1]["workflow_status_file"] is None


# ==================== start_claude_in_agents: None agent skip (line 636) ====================


class TestStartClaudeInAgentsNoneSkip:
    """Test that start_claude_in_agents skips None agents in loop."""

    @patch.object(TmuxUtils, "send_message_to_agent", return_value=True)
    def test_skips_none_agents_in_list(self, mock_send, tmp_workflow_with_agents):
        """When list_agents returns a list containing None, those are skipped."""
        project = tmp_workflow_with_agents.parent.parent
        orc = Orchestrator(project_path=str(project))

        # Patch list_agents to return a list with None mixed in
        registry = orc._get_registry(str(project))
        original_list = registry.list_agents()
        with patch.object(type(registry), "list_agents", return_value=[None] + original_list):
            # Re-patch _get_registry to return our modified registry
            with patch.object(orc, "_get_registry", return_value=registry):
                results = orc.start_claude_in_agents(str(project))

        # None agents should be skipped, only real agents get results
        assert len(results) == len(original_list)
        assert all(v is True for v in results.values())


# ==================== cmd_init (lines 694-714) ====================


class TestCmdInit:
    @patch("lib.orchestrator.Orchestrator.create_project_session")
    def test_success(self, mock_create, capsys):
        mock_create.return_value = {
            "session": "mysess",
            "project_path": "/tmp/proj",
            "agents": [
                {"agent_id": "pm", "role": "pm"},
                {"agent_id": "developer", "role": "developer"},
            ],
            "directory_created": False,
        }
        args = argparse.Namespace(session="mysess", path="/tmp/proj", no_pm=False, no_developer=False)
        ret = cmd_init(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "Created session: mysess" in captured.out
        assert "Project path: /tmp/proj" in captured.out
        assert "Agents created: 2" in captured.out
        assert "pm (pm)" in captured.out
        assert "developer (developer)" in captured.out

    @patch("lib.orchestrator.Orchestrator.create_project_session")
    def test_error(self, mock_create, capsys):
        mock_create.return_value = {"error": "Failed to create session: mysess"}
        args = argparse.Namespace(session="mysess", path="/tmp/proj", no_pm=False, no_developer=False)
        ret = cmd_init(args)
        assert ret == 1
        captured = capsys.readouterr()
        assert "Error:" in captured.out

    @patch("lib.orchestrator.Orchestrator.create_project_session")
    def test_directory_created(self, mock_create, capsys):
        mock_create.return_value = {
            "session": "mysess",
            "project_path": "/tmp/new_proj",
            "agents": [],
            "directory_created": True,
        }
        args = argparse.Namespace(session="mysess", path="/tmp/new_proj", no_pm=False, no_developer=False)
        ret = cmd_init(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "(directory created)" in captured.out

    @patch("lib.orchestrator.Orchestrator.create_project_session")
    def test_uses_cwd_when_no_path(self, mock_create):
        mock_create.return_value = {
            "session": "s",
            "project_path": os.getcwd(),
            "agents": [],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path=None, no_pm=False, no_developer=False)
        cmd_init(args)
        mock_create.assert_called_once_with(
            session_name="s",
            project_path=os.getcwd(),
            with_pm=True,
            with_developer=True,
        )

    @patch("lib.orchestrator.Orchestrator.create_project_session")
    def test_no_pm_flag(self, mock_create):
        mock_create.return_value = {
            "session": "s",
            "project_path": "/p",
            "agents": [],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path="/p", no_pm=True, no_developer=False)
        cmd_init(args)
        mock_create.assert_called_once_with(
            session_name="s",
            project_path="/p",
            with_pm=False,
            with_developer=True,
        )


# ==================== cmd_status (lines 719-727) ====================


class TestCmdStatus:
    @patch("lib.orchestrator.Orchestrator.get_system_status")
    def test_json_output(self, mock_status, capsys):
        mock_status.return_value = {"sessions": [], "agents": [], "timestamp": "2026-01-01"}
        args = argparse.Namespace(snapshot=False)
        ret = cmd_status(args)
        assert ret == 0
        captured = capsys.readouterr()
        parsed = json.loads(captured.out)
        assert parsed["timestamp"] == "2026-01-01"

    @patch("lib.orchestrator.Orchestrator.create_snapshot")
    def test_snapshot_output(self, mock_snapshot, capsys):
        mock_snapshot.return_value = "=== Snapshot ===\nAll good"
        args = argparse.Namespace(snapshot=True)
        ret = cmd_status(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "=== Snapshot ===" in captured.out


# ==================== cmd_deploy (lines 732-773) ====================


class TestCmdDeploy:
    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_default_team_no_config(self, mock_deploy, capsys):
        mock_deploy.return_value = {
            "session": "mysess",
            "agents": [
                {"agent_id": "pm", "role": "pm"},
                {"agent_id": "developer", "role": "developer"},
            ],
            "directory_created": False,
        }
        args = argparse.Namespace(session="mysess", path="/tmp/proj", config=None, panes=False)
        ret = cmd_deploy(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "Deployed team to: mysess" in captured.out
        # Verify default team config passed
        mock_deploy.assert_called_once_with(
            session_name="mysess",
            project_path="/tmp/proj",
            team_config=[{"role": "pm"}, {"role": "developer"}],
            project_context=None,
            use_panes=False,
        )

    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_with_config_file_list_format(self, mock_deploy, capsys, tmp_path):
        config_file = tmp_path / "team.json"
        config_data = [{"role": "pm"}, {"role": "qa"}]
        config_file.write_text(json.dumps(config_data))

        mock_deploy.return_value = {
            "session": "s",
            "agents": [{"agent_id": "pm", "role": "pm"}],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path="/p", config=str(config_file), panes=False)
        ret = cmd_deploy(args)
        assert ret == 0
        mock_deploy.assert_called_once_with(
            session_name="s",
            project_path="/p",
            team_config=config_data,
            project_context=None,
            use_panes=False,
        )

    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_with_config_file_dict_format(self, mock_deploy, capsys, tmp_path):
        config_file = tmp_path / "team.json"
        config_data = {
            "project_context": {"name": "MyProject"},
            "agents": [{"role": "developer"}],
        }
        config_file.write_text(json.dumps(config_data))

        mock_deploy.return_value = {
            "session": "s",
            "agents": [],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path="/p", config=str(config_file), panes=False)
        ret = cmd_deploy(args)
        assert ret == 0
        mock_deploy.assert_called_once_with(
            session_name="s",
            project_path="/p",
            team_config=[{"role": "developer"}],
            project_context={"name": "MyProject"},
            use_panes=False,
        )

    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_error_result(self, mock_deploy, capsys):
        mock_deploy.return_value = {"error": "Failed to create session"}
        args = argparse.Namespace(session="s", path="/p", config=None, panes=False)
        ret = cmd_deploy(args)
        assert ret == 1
        captured = capsys.readouterr()
        assert "Error:" in captured.out

    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_directory_created(self, mock_deploy, capsys):
        mock_deploy.return_value = {
            "session": "s",
            "agents": [],
            "directory_created": True,
        }
        args = argparse.Namespace(session="s", path="/p", config=None, panes=False)
        ret = cmd_deploy(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "(directory created)" in captured.out

    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_uses_cwd_when_no_path(self, mock_deploy):
        mock_deploy.return_value = {
            "session": "s",
            "agents": [],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path=None, config=None, panes=False)
        cmd_deploy(args)
        call_kwargs = mock_deploy.call_args
        assert call_kwargs[1]["project_path"] == os.getcwd()

    @patch("lib.orchestrator.Orchestrator.deploy_team")
    def test_panes_flag(self, mock_deploy):
        mock_deploy.return_value = {
            "session": "s",
            "agents": [],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path="/p", config=None, panes=True)
        cmd_deploy(args)
        mock_deploy.assert_called_once_with(
            session_name="s",
            project_path="/p",
            team_config=[{"role": "pm"}, {"role": "developer"}],
            project_context=None,
            use_panes=True,
        )


# ==================== cmd_start (lines 778-787) ====================


class TestCmdStart:
    @patch("lib.orchestrator.Orchestrator.start_claude_in_agents")
    def test_all_success(self, mock_start, capsys):
        mock_start.return_value = {"pm": True, "developer": True}
        args = argparse.Namespace(agents=[])
        ret = cmd_start(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "pm: started" in captured.out
        assert "developer: started" in captured.out
        # Empty list means None passed for agent_ids
        mock_start.assert_called_once_with(None)

    @patch("lib.orchestrator.Orchestrator.start_claude_in_agents")
    def test_some_fail(self, mock_start, capsys):
        mock_start.return_value = {"pm": True, "developer": False}
        args = argparse.Namespace(agents=["pm", "developer"])
        ret = cmd_start(args)
        assert ret == 1
        captured = capsys.readouterr()
        assert "pm: started" in captured.out
        assert "developer: failed" in captured.out

    @patch("lib.orchestrator.Orchestrator.start_claude_in_agents")
    def test_specific_agents(self, mock_start, capsys):
        mock_start.return_value = {"qa": True}
        args = argparse.Namespace(agents=["qa"])
        ret = cmd_start(args)
        assert ret == 0
        mock_start.assert_called_once_with(["qa"])

    @patch("lib.orchestrator.Orchestrator.start_claude_in_agents")
    def test_empty_results(self, mock_start, capsys):
        """When no agents found, all() of empty iterable is True, so returns 0."""
        mock_start.return_value = {}
        args = argparse.Namespace(agents=[])
        ret = cmd_start(args)
        assert ret == 0


# ==================== cmd_brief (lines 792-803) ====================


class TestCmdBrief:
    @patch("lib.orchestrator.Orchestrator.brief_team")
    def test_team_briefing_success(self, mock_brief, capsys):
        mock_brief.return_value = {"developer": True, "qa": True}
        args = argparse.Namespace(team=True, target="/path/proj", message="Hello team")
        ret = cmd_brief(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "developer: sent" in captured.out
        assert "qa: sent" in captured.out

    @patch("lib.orchestrator.Orchestrator.brief_team")
    def test_team_briefing_failure(self, mock_brief, capsys):
        mock_brief.return_value = {"developer": True, "qa": False}
        args = argparse.Namespace(team=True, target="/path/proj", message="Hello team")
        ret = cmd_brief(args)
        assert ret == 1
        captured = capsys.readouterr()
        assert "qa: failed" in captured.out

    @patch("lib.orchestrator.Orchestrator.brief_agent")
    def test_single_agent_success(self, mock_brief, capsys):
        mock_brief.return_value = True
        args = argparse.Namespace(team=False, target="%5", message="Hello agent")
        ret = cmd_brief(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "Briefing sent" in captured.out

    @patch("lib.orchestrator.Orchestrator.brief_agent")
    def test_single_agent_failure(self, mock_brief, capsys):
        mock_brief.return_value = False
        args = argparse.Namespace(team=False, target="%5", message="Hello agent")
        ret = cmd_brief(args)
        assert ret == 1
        captured = capsys.readouterr()
        assert "Failed to send briefing" in captured.out


# ==================== cmd_check (lines 808-813) ====================


class TestCmdCheck:
    @patch("lib.orchestrator.Orchestrator.check_agent_status")
    def test_prints_output(self, mock_check, capsys):
        mock_check.return_value = "Last 30 lines of agent output..."
        args = argparse.Namespace(agent="%5", lines=30)
        ret = cmd_check(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "Last 30 lines of agent output..." in captured.out
        mock_check.assert_called_once_with("%5", 30)

    @patch("lib.orchestrator.Orchestrator.check_agent_status")
    def test_custom_lines(self, mock_check, capsys):
        mock_check.return_value = "output"
        args = argparse.Namespace(agent="dev", lines=50)
        ret = cmd_check(args)
        assert ret == 0
        mock_check.assert_called_once_with("dev", 50)


# ==================== cmd_deploy_pm (lines 818-845) ====================


class TestCmdDeployPm:
    @patch("lib.orchestrator.Orchestrator.start_pm_with_planning_briefing")
    @patch("lib.orchestrator.Orchestrator.deploy_pm_only")
    def test_success(self, mock_deploy, mock_start, capsys):
        mock_deploy.return_value = {
            "session": "mysess",
            "project_path": "/tmp/proj",
            "pm_target": "%5",
            "agents": [{"agent_id": "pm", "role": "pm"}],
            "directory_created": False,
        }
        args = argparse.Namespace(session="mysess", path="/tmp/proj", workflow="001-feat", existing=False)
        ret = cmd_deploy_pm(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "Created session: mysess" in captured.out
        assert "PM deployed at: %5" in captured.out
        assert "Starting PM with planning briefing" in captured.out
        assert "tmux attach -t mysess" in captured.out
        mock_start.assert_called_once_with("%5", "/tmp/proj")

    @patch("lib.orchestrator.Orchestrator.deploy_pm_only")
    def test_error(self, mock_deploy, capsys):
        mock_deploy.return_value = {"error": "Failed to create session"}
        args = argparse.Namespace(session="s", path="/p", workflow=None, existing=False)
        ret = cmd_deploy_pm(args)
        assert ret == 1
        captured = capsys.readouterr()
        assert "Error:" in captured.out

    @patch("lib.orchestrator.Orchestrator.start_pm_with_planning_briefing")
    @patch("lib.orchestrator.Orchestrator.deploy_pm_only")
    def test_directory_created(self, mock_deploy, mock_start, capsys):
        mock_deploy.return_value = {
            "session": "s",
            "project_path": "/p",
            "pm_target": "%1",
            "agents": [],
            "directory_created": True,
        }
        args = argparse.Namespace(session="s", path="/p", workflow=None, existing=False)
        ret = cmd_deploy_pm(args)
        assert ret == 0
        captured = capsys.readouterr()
        assert "(directory created)" in captured.out

    @patch("lib.orchestrator.Orchestrator.start_pm_with_planning_briefing")
    @patch("lib.orchestrator.Orchestrator.deploy_pm_only")
    def test_uses_cwd_when_no_path(self, mock_deploy, mock_start):
        mock_deploy.return_value = {
            "session": "s",
            "project_path": os.getcwd(),
            "pm_target": "%1",
            "agents": [],
            "directory_created": False,
        }
        args = argparse.Namespace(session="s", path=None, workflow=None, existing=False)
        cmd_deploy_pm(args)
        mock_deploy.assert_called_once_with(
            session_name="s",
            project_path=os.getcwd(),
            workflow_name=None,
            is_existing_project=False,
        )


# ==================== main() (lines 849-920) ====================


class TestMain:
    @patch("sys.argv", ["orchestrator.py"])
    @patch("lib.orchestrator.argparse.ArgumentParser.print_help")
    def test_no_command_prints_help(self, mock_help):
        ret = main()
        assert ret == 0
        mock_help.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "init", "mysess", "-p", "/tmp/proj"])
    @patch("lib.orchestrator.cmd_init", return_value=0)
    def test_dispatches_init(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "status"])
    @patch("lib.orchestrator.cmd_status", return_value=0)
    def test_dispatches_status(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "status", "-s"])
    @patch("lib.orchestrator.cmd_status", return_value=0)
    def test_dispatches_status_snapshot(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "deploy", "mysess", "-p", "/tmp/proj"])
    @patch("lib.orchestrator.cmd_deploy", return_value=0)
    def test_dispatches_deploy(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "deploy-pm", "mysess", "-p", "/tmp/proj", "-w", "001-feat"])
    @patch("lib.orchestrator.cmd_deploy_pm", return_value=0)
    def test_dispatches_deploy_pm(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "start"])
    @patch("lib.orchestrator.cmd_start", return_value=0)
    def test_dispatches_start(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "brief", "%5", "hello"])
    @patch("lib.orchestrator.cmd_brief", return_value=0)
    def test_dispatches_brief(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "check", "%5"])
    @patch("lib.orchestrator.cmd_check", return_value=0)
    def test_dispatches_check(self, mock_cmd):
        ret = main()
        assert ret == 0
        mock_cmd.assert_called_once()

    @patch("sys.argv", ["orchestrator.py", "init", "mysess"])
    @patch("lib.orchestrator.cmd_init", return_value=1)
    def test_returns_handler_exit_code(self, mock_cmd):
        ret = main()
        assert ret == 1


# ==================== __name__ == "__main__" (line 920) ====================


class TestMainEntry:
    @patch("lib.orchestrator.main", return_value=0)
    @patch("lib.orchestrator.sys.exit")
    def test_main_entry_point(self, mock_exit, mock_main):
        """Test the if __name__ == '__main__' block by importing and running."""
        # We can't easily test the __name__ == "__main__" guard directly,
        # but we can test that main() is callable and sys.exit is called
        # by simulating what the guard does
        import lib.orchestrator as mod
        mod.sys.exit(mod.main())
        mock_main.assert_called_once()
        mock_exit.assert_called_with(0)


class TestMainUnknownCommand:
    """Test main() with an unknown command that bypasses argparse subparser validation."""

    def test_unknown_command_branch(self, capsys):
        """Exercise the else branch in main() where handler is None.

        argparse subparsers prevent truly unknown commands from reaching the
        cmd_map lookup, so we patch parse_args to return a Namespace with an
        unknown command value.
        """
        fake_args = argparse.Namespace(command="nonexistent_cmd")
        with patch("lib.orchestrator.argparse.ArgumentParser.parse_args", return_value=fake_args):
            ret = main()
        assert ret == 1
        captured = capsys.readouterr()
        assert "Unknown command: nonexistent_cmd" in captured.out


class TestMainEntryRunpy:
    """Test the __name__ == '__main__' guard via runpy."""

    @patch("sys.argv", ["lib/orchestrator.py"])
    @patch("lib.orchestrator.argparse.ArgumentParser.print_help")
    def test_runpy_invocation(self, mock_help):
        """Simulate running the module as __main__."""
        import runpy
        with pytest.raises(SystemExit) as exc_info:
            runpy.run_module("lib.orchestrator", run_name="__main__", alter_sys=True)
        assert exc_info.value.code == 0
