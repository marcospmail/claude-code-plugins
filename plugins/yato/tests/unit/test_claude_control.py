"""Tests for lib/claude_control.py — CLI controller for Claude agents."""

import argparse
import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch, PropertyMock

import pytest
import yaml

from lib.claude_control import TmuxController, ClaudeControl, main
from lib.session_registry import Agent
from lib.workflow_registry import WorkflowRegistry


# ==================== TmuxController.run_tmux ====================


class TestTmuxControllerRunTmux:
    @patch("lib.claude_control.subprocess.run")
    def test_without_tmux_socket(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="ok")
        TmuxController.run_tmux(["list-sessions"])
        args = mock_run.call_args[0][0]
        assert args == ["tmux", "list-sessions"]

    @patch("lib.claude_control.subprocess.run")
    def test_with_tmux_socket(self, mock_run, clean_env):
        clean_env.setenv("TMUX_SOCKET", "mysock")
        mock_run.return_value = MagicMock(returncode=0, stdout="ok")
        TmuxController.run_tmux(["list-sessions"])
        args = mock_run.call_args[0][0]
        assert args == ["tmux", "-L", "mysock", "list-sessions"]


# ==================== TmuxController.list_sessions ====================


class TestTmuxControllerListSessions:
    @patch("lib.claude_control.subprocess.run")
    def test_parse_output(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="mysession:3:1\nother:2:0\n"
        )
        sessions = TmuxController.list_sessions()
        assert len(sessions) == 2
        assert sessions[0]["name"] == "mysession"
        assert sessions[0]["windows"] == 3
        assert sessions[0]["attached"] is True
        assert sessions[1]["name"] == "other"
        assert sessions[1]["attached"] is False

    @patch("lib.claude_control.subprocess.run")
    def test_empty_output(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="")
        sessions = TmuxController.list_sessions()
        assert sessions == []

    @patch("lib.claude_control.subprocess.run")
    def test_error_returns_empty(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        sessions = TmuxController.list_sessions()
        assert sessions == []


# ==================== TmuxController.list_windows ====================


class TestTmuxControllerListWindows:
    @patch("lib.claude_control.subprocess.run")
    def test_parse_output(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="0:main:/home/user\n1:dev:/home/user/dev\n"
        )
        windows = TmuxController.list_windows("sess")
        assert len(windows) == 2
        assert windows[0]["index"] == 0
        assert windows[0]["name"] == "main"
        assert windows[0]["path"] == "/home/user"

    @patch("lib.claude_control.subprocess.run")
    def test_paths_with_colons(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(
            returncode=0,
            stdout="0:main:C:/Users/test\n"
        )
        windows = TmuxController.list_windows("sess")
        assert windows[0]["path"] == "C:/Users/test"

    @patch("lib.claude_control.subprocess.run")
    def test_error_returns_empty(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        windows = TmuxController.list_windows("sess")
        assert windows == []


# ==================== TmuxController.capture_pane ====================


class TestTmuxControllerCapturePane:
    @patch("lib.claude_control.subprocess.run")
    def test_success(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="output line\n")
        result = TmuxController.capture_pane("sess:0")
        assert result == "output line\n"

    @patch("lib.claude_control.subprocess.run")
    def test_error(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1, stderr="pane not found")
        result = TmuxController.capture_pane("sess:0")
        assert "Error" in result


# ==================== TmuxController.send_keys ====================


class TestTmuxControllerSendKeys:
    @patch("time.sleep")
    @patch("lib.claude_control.subprocess.run")
    def test_with_enter(self, mock_run, mock_sleep, clean_env):
        mock_run.return_value = MagicMock(returncode=0)
        result = TmuxController.send_keys("sess:0", "hello")
        assert result is True
        assert mock_run.call_count == 2  # message + Enter
        mock_sleep.assert_called_once_with(0.5)

    @patch("lib.claude_control.subprocess.run")
    def test_without_enter(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0)
        result = TmuxController.send_keys("sess:0", "hello", send_enter=False)
        assert result is True
        assert mock_run.call_count == 1

    @patch("lib.claude_control.subprocess.run")
    def test_failure(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1)
        result = TmuxController.send_keys("sess:0", "hello")
        assert result is False


# ==================== TmuxController.create_window ====================


class TestTmuxControllerCreateWindow:
    @patch("lib.claude_control.subprocess.run")
    def test_success(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="3\n")
        result = TmuxController.create_window("sess", "mywin")
        assert result == 3

    @patch("lib.claude_control.subprocess.run")
    def test_with_path(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="1\n")
        TmuxController.create_window("sess", "mywin", path="/tmp/proj")
        args = mock_run.call_args[0][0]
        assert "-c" in args
        assert "/tmp/proj" in args

    @patch("lib.claude_control.subprocess.run")
    def test_failure(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        result = TmuxController.create_window("sess", "mywin")
        assert result is None

    @patch("lib.claude_control.subprocess.run")
    def test_non_numeric_output(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0, stdout="not-a-number\n")
        result = TmuxController.create_window("sess", "mywin")
        assert result is None


# ==================== TmuxController.session_exists ====================


class TestTmuxControllerSessionExists:
    @patch("lib.claude_control.subprocess.run")
    def test_exists(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=0)
        assert TmuxController.session_exists("sess") is True

    @patch("lib.claude_control.subprocess.run")
    def test_not_exists(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(returncode=1)
        assert TmuxController.session_exists("sess") is False


# ==================== ClaudeControl.__init__ ====================


class TestClaudeControlInit:
    def test_with_project_path(self, tmp_project):
        cc = ClaudeControl(project_path=str(tmp_project))
        assert cc.project_path is not None

    def test_without_project_path(self):
        cc = ClaudeControl()
        assert cc.project_path is None

    def test_lazy_registry(self, tmp_project):
        cc = ClaudeControl(project_path=str(tmp_project))
        assert cc._registry is None


# ==================== ClaudeControl.registry (lazy property) ====================


class TestClaudeControlRegistry:
    def test_lazy_loads_registry(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        cc = ClaudeControl(project_path=str(project))
        with patch.object(WorkflowRegistry, "from_project", return_value=MagicMock()) as mock_fp:
            reg = cc.registry
            assert reg is not None
            mock_fp.assert_called_once()

    def test_no_project_path_returns_none(self):
        cc = ClaudeControl()
        assert cc.registry is None

    def test_caches_registry(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        cc = ClaudeControl(project_path=str(project))
        mock_reg = MagicMock()
        with patch.object(WorkflowRegistry, "from_project", return_value=mock_reg):
            r1 = cc.registry
            r2 = cc.registry
        assert r1 is r2


# ==================== ClaudeControl.cmd_status ====================


class TestClaudeControlCmdStatus:
    def _make_args(self):
        return argparse.Namespace()

    def test_with_agents(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_status(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "pm" in captured.out.lower()

    def test_no_registry(self, capsys):
        cc = ClaudeControl()
        result = cc.cmd_status(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "No workflow found" in captured.out

    def test_no_agents(self, tmp_workflow, capsys):
        project = tmp_workflow.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_status(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "No registered agents" in captured.out


# ==================== ClaudeControl.cmd_list ====================


class TestClaudeControlCmdList:
    def _make_args(self, verbose=False):
        return argparse.Namespace(verbose=verbose)

    @patch.object(TmuxController, "list_sessions")
    @patch.object(TmuxController, "list_windows")
    def test_sessions_with_windows(self, mock_windows, mock_sessions, capsys, clean_env):
        mock_sessions.return_value = [
            {"name": "sess", "windows": 2, "attached": True}
        ]
        mock_windows.return_value = [
            {"index": 0, "name": "main", "path": "/tmp"},
            {"index": 1, "name": "dev", "path": "/tmp"},
        ]
        cc = ClaudeControl()
        result = cc.cmd_list(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "sess" in captured.out
        assert "(attached)" in captured.out

    @patch.object(TmuxController, "list_sessions")
    def test_no_sessions(self, mock_sessions, capsys, clean_env):
        mock_sessions.return_value = []
        cc = ClaudeControl()
        result = cc.cmd_list(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "No tmux sessions found" in captured.out

    @patch.object(TmuxController, "list_sessions")
    @patch.object(TmuxController, "list_windows")
    def test_verbose_mode(self, mock_windows, mock_sessions, capsys, clean_env):
        mock_sessions.return_value = [
            {"name": "sess", "windows": 1, "attached": False}
        ]
        mock_windows.return_value = [
            {"index": 0, "name": "main", "path": "/home/user"},
        ]
        cc = ClaudeControl()
        result = cc.cmd_list(self._make_args(verbose=True))
        assert result == 0
        captured = capsys.readouterr()
        assert "Path:" in captured.out


# ==================== ClaudeControl.cmd_send ====================


class TestClaudeControlCmdSend:
    def _make_args(self, target="sess:0", message="hello"):
        return argparse.Namespace(target=target, message=message)

    @patch.object(TmuxController, "session_exists", return_value=True)
    @patch.object(TmuxController, "send_keys", return_value=True)
    def test_success(self, mock_send, mock_exists, capsys, clean_env):
        cc = ClaudeControl()
        result = cc.cmd_send(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "Message sent" in captured.out

    def test_invalid_target(self, capsys, clean_env):
        cc = ClaudeControl()
        result = cc.cmd_send(self._make_args(target="no-colon"))
        assert result == 1
        captured = capsys.readouterr()
        assert "Invalid target" in captured.out

    @patch.object(TmuxController, "session_exists", return_value=False)
    def test_session_not_exists(self, mock_exists, capsys, clean_env):
        cc = ClaudeControl()
        result = cc.cmd_send(self._make_args())
        assert result == 1
        captured = capsys.readouterr()
        assert "does not exist" in captured.out

    @patch.object(TmuxController, "session_exists", return_value=True)
    @patch.object(TmuxController, "send_keys", return_value=False)
    def test_send_failure(self, mock_send, mock_exists, capsys, clean_env):
        cc = ClaudeControl()
        result = cc.cmd_send(self._make_args())
        assert result == 1
        captured = capsys.readouterr()
        assert "Failed" in captured.out


# ==================== ClaudeControl.cmd_read ====================


class TestClaudeControlCmdRead:
    @patch.object(TmuxController, "capture_pane", return_value="line 1\nline 2\n")
    def test_capture_output(self, mock_capture, capsys, clean_env):
        cc = ClaudeControl()
        args = argparse.Namespace(target="sess:0", lines=50)
        result = cc.cmd_read(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "line 1" in captured.out


# ==================== ClaudeControl.cmd_register ====================


class TestClaudeControlCmdRegister:
    def _make_args(self, target="sess:0", role="developer", name=None, model=None):
        return argparse.Namespace(target=target, role=role, name=name, model=model)

    def test_valid_target(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_register(self._make_args(target="sess:3", role="qa", name="qa2"))
        assert result == 0
        captured = capsys.readouterr()
        assert "Registered" in captured.out

    def test_with_pane(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_register(self._make_args(target="sess:1.0", role="developer"))
        assert result == 0

    def test_invalid_target(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_register(self._make_args(target="no-colon"))
        assert result == 1
        captured = capsys.readouterr()
        assert "Invalid target" in captured.out

    def test_no_registry(self, capsys):
        cc = ClaudeControl()
        result = cc.cmd_register(self._make_args())
        assert result == 1
        captured = capsys.readouterr()
        assert "No workflow found" in captured.out

    def test_invalid_window_number(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_register(self._make_args(target="sess:abc"))
        assert result == 1
        captured = capsys.readouterr()
        assert "Window must be a number" in captured.out

    def test_invalid_window_number_with_pane(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_register(self._make_args(target="sess:abc.0"))
        assert result == 1
        captured = capsys.readouterr()
        assert "Window must be a number" in captured.out


# ==================== ClaudeControl.cmd_unregister ====================


class TestClaudeControlCmdUnregister:
    def test_found(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        args = argparse.Namespace(name="developer")
        result = cc.cmd_unregister(args)
        assert result == 0
        captured = capsys.readouterr()
        assert "Unregistered" in captured.out

    def test_not_found(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        args = argparse.Namespace(name="nonexistent")
        result = cc.cmd_unregister(args)
        assert result == 1
        captured = capsys.readouterr()
        assert "not found" in captured.out

    def test_no_registry(self, capsys):
        cc = ClaudeControl()
        args = argparse.Namespace(name="dev")
        result = cc.cmd_unregister(args)
        assert result == 1
        captured = capsys.readouterr()
        assert "No workflow found" in captured.out


# ==================== ClaudeControl.cmd_team ====================


class TestClaudeControlCmdTeam:
    def _make_args(self):
        return argparse.Namespace()

    def test_with_team(self, tmp_workflow_with_agents, capsys):
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_team(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "developer" in captured.out
        assert "qa" in captured.out

    def test_no_pm(self, tmp_path, capsys):
        wf = tmp_path / "project" / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text(yaml.dump({"pm": None, "agents": []}))
        project = tmp_path / "project"
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_team(self._make_args())
        assert result == 1
        captured = capsys.readouterr()
        assert "No PM found" in captured.out

    def test_no_registry(self, capsys):
        cc = ClaudeControl()
        result = cc.cmd_team(self._make_args())
        assert result == 1
        captured = capsys.readouterr()
        assert "No workflow found" in captured.out

    def test_pm_with_no_team_members(self, tmp_path, capsys):
        wf = tmp_path / "project" / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm", "session": "s", "window": 0, "pane_id": "%1", "model": "opus"},
            "agents": [],
        }))
        project = tmp_path / "project"
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_team(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "No team members" in captured.out


# ==================== ClaudeControl.cmd_list with agent info ====================


class TestCmdListAgentInfo:
    """Test cmd_list when registry returns agent info for windows (lines 215-217)."""

    def _make_args(self, verbose=False):
        return argparse.Namespace(verbose=verbose)

    @patch.object(TmuxController, "list_sessions")
    @patch.object(TmuxController, "list_windows")
    def test_agent_info_shown_in_output(self, mock_windows, mock_sessions, tmp_workflow_with_agents, capsys, clean_env):
        """When registry has an agent matching session:window, [role] should appear."""
        mock_sessions.return_value = [
            {"name": "test-session", "windows": 3, "attached": False}
        ]
        mock_windows.return_value = [
            {"index": 0, "name": "pm-window", "path": "/tmp"},
            {"index": 1, "name": "dev-window", "path": "/tmp"},
            {"index": 2, "name": "qa-window", "path": "/tmp"},
        ]
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_list(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "[pm]" in captured.out
        assert "[developer]" in captured.out
        assert "[qa]" in captured.out

    @patch.object(TmuxController, "list_sessions")
    @patch.object(TmuxController, "list_windows")
    def test_no_agent_info_for_unregistered_window(self, mock_windows, mock_sessions, tmp_workflow_with_agents, capsys, clean_env):
        """Windows without a matching agent should not show [role]."""
        mock_sessions.return_value = [
            {"name": "test-session", "windows": 1, "attached": False}
        ]
        mock_windows.return_value = [
            {"index": 99, "name": "unrelated", "path": "/tmp"},
        ]
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_list(self._make_args())
        assert result == 0
        captured = capsys.readouterr()
        assert "[" not in captured.out.split("unrelated")[1].split("\n")[0]

    @patch.object(TmuxController, "list_sessions")
    @patch.object(TmuxController, "list_windows")
    def test_agent_info_verbose(self, mock_windows, mock_sessions, tmp_workflow_with_agents, capsys, clean_env):
        """Agent info with verbose mode should show both role and path."""
        mock_sessions.return_value = [
            {"name": "test-session", "windows": 1, "attached": True}
        ]
        mock_windows.return_value = [
            {"index": 1, "name": "dev-window", "path": "/home/dev"},
        ]
        project = tmp_workflow_with_agents.parent.parent
        cc = ClaudeControl(project_path=str(project))
        result = cc.cmd_list(self._make_args(verbose=True))
        assert result == 0
        captured = capsys.readouterr()
        assert "[developer]" in captured.out
        assert "Path:" in captured.out


# ==================== main() function ====================


class TestMainFunction:
    """Test the main() CLI entry point (lines 348-422)."""

    @patch("sys.argv", ["claude_control"])
    @patch("lib.claude_control.ClaudeControl")
    def test_no_command_prints_help_returns_zero(self, mock_cc_cls, capsys):
        """No subcommand should print help and return 0."""
        result = main()
        assert result == 0
        captured = capsys.readouterr()
        assert "usage:" in captured.out.lower() or "Claude Control" in captured.out

    @patch("sys.argv", ["claude_control", "status"])
    @patch("lib.claude_control.ClaudeControl")
    def test_status_command_dispatches(self, mock_cc_cls):
        """'status' command should call cmd_status on the controller."""
        mock_controller = MagicMock()
        mock_controller.cmd_status.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        mock_controller.cmd_status.assert_called_once()

    @patch("sys.argv", ["claude_control", "list"])
    @patch("lib.claude_control.ClaudeControl")
    def test_list_command_dispatches(self, mock_cc_cls):
        """'list' command should call cmd_list on the controller."""
        mock_controller = MagicMock()
        mock_controller.cmd_list.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        mock_controller.cmd_list.assert_called_once()

    @patch("sys.argv", ["claude_control", "list", "-v"])
    @patch("lib.claude_control.ClaudeControl")
    def test_list_verbose_flag(self, mock_cc_cls):
        """'list -v' should pass verbose=True in args."""
        mock_controller = MagicMock()
        mock_controller.cmd_list.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_list.call_args[0][0]
        assert call_args.verbose is True

    @patch("sys.argv", ["claude_control", "send", "mysess:0", "hello world"])
    @patch("lib.claude_control.ClaudeControl")
    def test_send_command_dispatches(self, mock_cc_cls):
        """'send' command should call cmd_send with target and message."""
        mock_controller = MagicMock()
        mock_controller.cmd_send.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_send.call_args[0][0]
        assert call_args.target == "mysess:0"
        assert call_args.message == "hello world"

    @patch("sys.argv", ["claude_control", "read", "mysess:1", "-n", "100"])
    @patch("lib.claude_control.ClaudeControl")
    def test_read_command_with_lines(self, mock_cc_cls):
        """'read' command should pass target and lines count."""
        mock_controller = MagicMock()
        mock_controller.cmd_read.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_read.call_args[0][0]
        assert call_args.target == "mysess:1"
        assert call_args.lines == 100

    @patch("sys.argv", ["claude_control", "register", "mysess:2", "developer", "-n", "dev1", "-m", "opus"])
    @patch("lib.claude_control.ClaudeControl")
    def test_register_command_with_options(self, mock_cc_cls):
        """'register' command should pass target, role, name, and model."""
        mock_controller = MagicMock()
        mock_controller.cmd_register.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_register.call_args[0][0]
        assert call_args.target == "mysess:2"
        assert call_args.role == "developer"
        assert call_args.name == "dev1"
        assert call_args.model == "opus"

    @patch("sys.argv", ["claude_control", "unregister", "dev1"])
    @patch("lib.claude_control.ClaudeControl")
    def test_unregister_command_dispatches(self, mock_cc_cls):
        """'unregister' command should pass agent name."""
        mock_controller = MagicMock()
        mock_controller.cmd_unregister.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_unregister.call_args[0][0]
        assert call_args.name == "dev1"

    @patch("sys.argv", ["claude_control", "team"])
    @patch("lib.claude_control.ClaudeControl")
    def test_team_command_dispatches(self, mock_cc_cls):
        """'team' command should call cmd_team."""
        mock_controller = MagicMock()
        mock_controller.cmd_team.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        mock_controller.cmd_team.assert_called_once()

    @patch("sys.argv", ["claude_control", "-p", "/tmp/myproject", "status"])
    @patch("lib.claude_control.ClaudeControl")
    def test_project_path_argument(self, mock_cc_cls):
        """--project-path should be passed to ClaudeControl constructor."""
        mock_controller = MagicMock()
        mock_controller.cmd_status.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        mock_cc_cls.assert_called_once_with(project_path="/tmp/myproject", workflow_name=None)

    @patch("sys.argv", ["claude_control", "-w", "001-feature", "status"])
    @patch("lib.claude_control.ClaudeControl")
    def test_workflow_argument(self, mock_cc_cls):
        """--workflow should be passed to ClaudeControl constructor."""
        mock_controller = MagicMock()
        mock_controller.cmd_status.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_kwargs = mock_cc_cls.call_args[1]
        assert call_kwargs["workflow_name"] == "001-feature"

    @patch("sys.argv", ["claude_control", "status"])
    @patch("lib.claude_control.ClaudeControl")
    @patch("lib.claude_control.Path")
    def test_auto_detect_project_path_from_cwd(self, mock_path_cls, mock_cc_cls):
        """When no --project-path is given, detect .workflow in cwd."""
        mock_cwd = MagicMock()
        mock_cwd.__truediv__ = MagicMock(return_value=MagicMock())
        (mock_cwd / ".workflow").exists.return_value = True
        mock_cwd.__str__ = MagicMock(return_value="/fake/cwd")
        mock_path_cls.cwd.return_value = mock_cwd
        mock_controller = MagicMock()
        mock_controller.cmd_status.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_cc_cls.call_args
        assert call_args[1]["project_path"] == str(mock_cwd)

    @patch("sys.argv", ["claude_control", "status"])
    @patch("lib.claude_control.ClaudeControl")
    @patch("lib.claude_control.Path")
    def test_no_workflow_in_cwd_passes_none(self, mock_path_cls, mock_cc_cls):
        """When cwd has no .workflow, project_path should be None."""
        mock_cwd = MagicMock()
        mock_cwd.__truediv__ = MagicMock(return_value=MagicMock())
        (mock_cwd / ".workflow").exists.return_value = False
        mock_path_cls.cwd.return_value = mock_cwd
        mock_controller = MagicMock()
        mock_controller.cmd_status.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_cc_cls.call_args
        assert call_args[1]["project_path"] is None

    @patch("sys.argv", ["claude_control", "read", "sess:0"])
    @patch("lib.claude_control.ClaudeControl")
    def test_read_default_lines(self, mock_cc_cls):
        """'read' without -n should default to 50 lines."""
        mock_controller = MagicMock()
        mock_controller.cmd_read.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_read.call_args[0][0]
        assert call_args.lines == 50

    @patch("sys.argv", ["claude_control", "register", "sess:0", "qa"])
    @patch("lib.claude_control.ClaudeControl")
    def test_register_defaults(self, mock_cc_cls):
        """'register' without -n/-m should have None defaults."""
        mock_controller = MagicMock()
        mock_controller.cmd_register.return_value = 0
        mock_cc_cls.return_value = mock_controller
        result = main()
        assert result == 0
        call_args = mock_controller.cmd_register.call_args[0][0]
        assert call_args.name is None
        assert call_args.model is None
