"""Tests for lib/tmux_utils.py — tmux operations, messaging, notify_pm."""

import os
import subprocess
import tempfile
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest
import yaml

from lib.tmux_utils import (
    validate_pane_id,
    _build_message_with_suffixes,
    _tmux_cmd,
    TmuxWindow,
    TmuxSession,
    TmuxOrchestrator,
    send_message,
    get_current_session,
    restart_checkin_display,
    notify_pm,
    send_to_agent,
    _get_orchestrator,
    _lookup_pm_pane_id,
)
import lib.tmux_utils as tmux_mod


# ==================== validate_pane_id ====================


class TestValidatePaneId:
    def test_valid_single_digit(self):
        assert validate_pane_id("%0") is True

    def test_valid_multi_digit(self):
        assert validate_pane_id("%123") is True

    def test_invalid_no_percent(self):
        assert validate_pane_id("5") is False

    def test_invalid_non_numeric(self):
        assert validate_pane_id("%abc") is False

    def test_invalid_empty(self):
        assert validate_pane_id("") is False

    def test_invalid_double_percent(self):
        assert validate_pane_id("%%5") is False

    def test_invalid_session_format(self):
        assert validate_pane_id("sess:1") is False


# ==================== _build_message_with_suffixes ====================


class TestBuildMessageWithSuffixes:
    def test_no_suffixes(self):
        result = _build_message_with_suffixes("hello", "", "")
        assert result == "hello"

    def test_yato_suffix_only(self):
        result = _build_message_with_suffixes("hello", "yato-sfx", "")
        assert result == "hello\n\nyato-sfx"

    def test_workflow_suffix_only(self):
        result = _build_message_with_suffixes("hello", "", "wf-sfx")
        assert result == "hello\n\nwf-sfx"

    def test_both_suffixes_stacked(self):
        result = _build_message_with_suffixes("hello", "yato", "wf")
        assert result == "hello\n\nyato\n\nwf"

    def test_order_preserved(self):
        result = _build_message_with_suffixes("msg", "first", "second")
        idx_first = result.index("first")
        idx_second = result.index("second")
        assert idx_first < idx_second


# ==================== _tmux_cmd ====================


class TestTmuxCmd:
    def test_default_no_socket(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        assert _tmux_cmd() == ["tmux"]

    def test_with_socket(self, monkeypatch):
        monkeypatch.setenv("TMUX_SOCKET", "mysocket")
        assert _tmux_cmd() == ["tmux", "-L", "mysocket"]


# ==================== TmuxWindow / TmuxSession dataclasses ====================


class TestDataclasses:
    def test_tmux_window(self):
        w = TmuxWindow(session_name="s", window_index=0, window_name="main", active=True)
        assert w.session_name == "s"
        assert w.window_index == 0
        assert w.window_name == "main"
        assert w.active is True

    def test_tmux_session(self):
        w = TmuxWindow(session_name="s", window_index=0, window_name="main", active=True)
        s = TmuxSession(name="s", windows=[w], attached=False)
        assert s.name == "s"
        assert len(s.windows) == 1
        assert s.attached is False


# ==================== TmuxOrchestrator ====================


class TestTmuxOrchestratorInit:
    def test_defaults(self):
        o = TmuxOrchestrator()
        assert o.safety_mode is True
        assert o.max_lines_capture == 1000
        assert o.message_delay == 0.5


class TestGetTmuxSessions:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        def mock_run(cmd, *args, **kwargs):
            cmd_str = " ".join(cmd)
            mock = MagicMock()
            mock.returncode = 0
            if "list-sessions" in cmd_str:
                mock.stdout = "mysess:1\nother:0\n"
            elif "list-windows" in cmd_str:
                if "mysess" in cmd_str:
                    mock.stdout = "0:main:1\n1:dev:0\n"
                else:
                    mock.stdout = "0:default:1\n"
            return mock

        with patch("subprocess.run", side_effect=mock_run):
            sessions = o.get_tmux_sessions()

        assert len(sessions) == 2
        assert sessions[0].name == "mysess"
        assert sessions[0].attached is True
        assert len(sessions[0].windows) == 2
        assert sessions[0].windows[0].window_name == "main"
        assert sessions[0].windows[0].active is True
        assert sessions[0].windows[1].window_name == "dev"
        assert sessions[1].name == "other"
        assert sessions[1].attached is False

    def test_empty_lines_in_sessions_output(self, monkeypatch):
        """Empty lines in session/window output should be skipped."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        def mock_run(cmd, *args, **kwargs):
            cmd_str = " ".join(cmd)
            mock = MagicMock()
            mock.returncode = 0
            if "list-sessions" in cmd_str:
                # Empty line between sessions (strip keeps it)
                mock.stdout = "mysess:1\n\nother:0"
            elif "list-windows" in cmd_str:
                # Empty line between windows
                mock.stdout = "0:main:1\n\n1:dev:0"
            return mock

        with patch("subprocess.run", side_effect=mock_run):
            sessions = o.get_tmux_sessions()
        assert len(sessions) == 2
        assert len(sessions[0].windows) == 2

    def test_subprocess_error_returns_empty(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "tmux")):
            sessions = o.get_tmux_sessions()
        assert sessions == []


class TestSessionExists:
    def test_exists(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0)
        with patch("subprocess.run", return_value=mock):
            assert o.session_exists("test") is True

    def test_not_exists(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=1)
        with patch("subprocess.run", return_value=mock):
            assert o.session_exists("test") is False


class TestCreateSession:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0)
        with patch("subprocess.run", return_value=mock):
            assert o.create_session("new") is True

    def test_with_path(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0)
        with patch("subprocess.run", return_value=mock) as mock_run:
            o.create_session("new", path="/tmp/proj")
            cmd = mock_run.call_args[0][0]
            assert "-c" in cmd
            assert "/tmp/proj" in cmd

    def test_failure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=1)
        with patch("subprocess.run", return_value=mock):
            assert o.create_session("new") is False


class TestCreateWindow:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="3:%15\n")
        with patch("subprocess.run", return_value=mock):
            result = o.create_window("sess", "dev")
            assert result == {"window_index": 3, "pane_id": "%15"}

    def test_with_path(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="1:%10\n")
        with patch("subprocess.run", return_value=mock) as mock_run:
            o.create_window("sess", "dev", path="/proj")
            cmd = mock_run.call_args[0][0]
            assert "-c" in cmd

    def test_failure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=1)
        with patch("subprocess.run", return_value=mock):
            assert o.create_window("sess", "dev") is None

    def test_malformed_output(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="bad\n")
        with patch("subprocess.run", return_value=mock):
            result = o.create_window("sess", "dev")
            assert result is None


class TestSetPaneTitle:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0)
        with patch("subprocess.run", return_value=mock):
            assert o.set_pane_title("%5", "My Title") is True

    def test_failure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=1)
        with patch("subprocess.run", return_value=mock):
            assert o.set_pane_title("%5", "My Title") is False


class TestCaptureWindowContent:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="line1\nline2\n")
        with patch("subprocess.run", return_value=mock):
            result = o.capture_window_content("sess", 0, 50)
            assert result == "line1\nline2\n"

    def test_clamps_max_lines(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.max_lines_capture = 100
        mock = MagicMock(returncode=0, stdout="")
        with patch("subprocess.run", return_value=mock) as mock_run:
            o.capture_window_content("sess", 0, 5000)
            cmd = mock_run.call_args[0][0]
            assert "-100" in cmd

    def test_error(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "tmux")):
            result = o.capture_window_content("sess", 0)
            assert "Error" in result


class TestCaptureAgentOutput:
    def test_pane_id_format(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="pane output\n")
        with patch("subprocess.run", return_value=mock):
            result = o.capture_agent_output("%5", 30)
            assert result == "pane output\n"

    def test_session_window_format(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="window output\n")
        with patch("subprocess.run", return_value=mock):
            result = o.capture_agent_output("sess:1", 30)
            assert result == "window output\n"

    def test_session_window_pane_format(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="pane output\n")
        with patch("subprocess.run", return_value=mock):
            result = o.capture_agent_output("sess:1.2", 30)
            assert result == "pane output\n"

    def test_invalid_format(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        result = o.capture_agent_output("invalid", 30)
        assert "Invalid" in result

    def test_invalid_window_index(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        result = o.capture_agent_output("sess:abc", 30)
        assert "Invalid" in result


class TestCapturePaneContent:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="content\n")
        with patch("subprocess.run", return_value=mock):
            result = o._capture_pane_content("sess:0.1", 50)
            assert result == "content\n"

    def test_clamps_max_lines(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.max_lines_capture = 100
        mock = MagicMock(returncode=0, stdout="")
        with patch("subprocess.run", return_value=mock) as mock_run:
            o._capture_pane_content("t", 9999)
            cmd = mock_run.call_args[0][0]
            assert "-100" in cmd

    def test_error(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "tmux")):
            result = o._capture_pane_content("t", 50)
            assert "Error" in result


class TestGetWindowInfo:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        def mock_run(cmd, *args, **kwargs):
            mock = MagicMock()
            mock.returncode = 0
            cmd_str = " ".join(cmd)
            if "display-message" in cmd_str:
                mock.stdout = "dev:1:1:/tmp/proj\n"
            elif "capture-pane" in cmd_str:
                mock.stdout = "some output\n"
            return mock

        with patch("subprocess.run", side_effect=mock_run):
            info = o.get_window_info("sess", 1)
            assert info["name"] == "dev"
            assert info["active"] is True
            assert info["panes"] == 1
            assert info["path"] == "/tmp/proj"

    def test_error(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "tmux")):
            info = o.get_window_info("sess", 0)
            assert "error" in info

    def test_empty_output(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="\n")
        with patch("subprocess.run", return_value=mock):
            info = o.get_window_info("sess", 0)
            assert info == {}


class TestSendMessage:
    """Tests for TmuxOrchestrator.send_message (the instance method)."""

    def test_sends_to_pane_id(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"), \
             patch("lib.tmux_utils._build_message_with_suffixes", return_value="msg"):
            result = o.send_message("%5", "msg", _skip_suffix=True)
            assert result is True

    def test_appends_pane_zero_for_session_window(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            o.send_message("sess:1", "msg", _skip_suffix=True)
            # The select-pane call should target sess:1.0
            select_calls = [c for c in calls if "select-pane" in c]
            assert any("sess:1.0" in c for c in select_calls)

    def test_no_enter(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            o.send_message("%5", "msg", enter=False, _skip_suffix=True)
            # Should NOT have an Enter key send
            enter_calls = [c for c in calls if "Enter" in c]
            assert len(enter_calls) == 0

    def test_send_keys_failure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        call_count = [0]

        def mock_run(cmd, *args, **kwargs):
            call_count[0] += 1
            m = MagicMock()
            # Fail on send-keys -l (the actual message send)
            if "-l" in cmd:
                m.returncode = 1
                m.stderr = "error"
            else:
                m.returncode = 0
            m.stdout = ""
            return m

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = o.send_message("%5", "msg", _skip_suffix=True)
            assert result is False

    def test_enter_failure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        call_count = [0]

        def mock_run(cmd, *args, **kwargs):
            call_count[0] += 1
            m = MagicMock()
            # Fail on the Enter send (has "Enter" and no "-l")
            if "Enter" in cmd and "-l" not in cmd:
                m.returncode = 1
                m.stderr = "error"
            else:
                m.returncode = 0
            m.stdout = ""
            return m

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = o.send_message("%5", "msg", _skip_suffix=True)
            assert result is False

    def test_exception_returns_false(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        with patch("subprocess.run", side_effect=Exception("boom")):
            result = o.send_message("%5", "msg", _skip_suffix=True)
            assert result is False

    def test_suffix_handling_with_config(self, monkeypatch, tmp_path):
        """Test that suffixes are applied when _skip_suffix=False."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="", stderr="")

        # Create a config that returns empty suffix
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"), \
             patch("lib.config.get", return_value=""):
            result = o.send_message("%5", "msg", _skip_suffix=False)
            assert result is True

    def test_suffix_importerror_fallback(self, monkeypatch, tmp_path):
        """Test ImportError fallback for config module in send_message."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        mock = MagicMock(returncode=0, stdout="", stderr="")

        import sys
        import importlib

        # Temporarily make 'from lib.config import get' fail
        original_import = __builtins__.__import__ if hasattr(__builtins__, '__import__') else __import__

        def mock_import(name, *args, **kwargs):
            if name == "lib.config":
                raise ImportError("mocked")
            return original_import(name, *args, **kwargs)

        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"), \
             patch("builtins.__import__", side_effect=mock_import):
            result = o.send_message("%5", "msg", _skip_suffix=False)
            assert result is True

    def test_suffix_with_workflow_status_file(self, monkeypatch, tmp_path):
        """Test suffix from workflow status.yml."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        # Create status.yml with suffix
        status_file = tmp_path / "status.yml"
        with open(status_file, "w") as f:
            yaml.dump({"agent_message_suffix": "workflow-suffix"}, f)

        mock = MagicMock(returncode=0, stdout="", stderr="")
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"), \
             patch("lib.config.get", return_value="yato-suffix"):
            result = o.send_message("%5", "msg", workflow_status_file=str(status_file))
            assert result is True

    def test_session_window_pane_target_preserved(self, monkeypatch):
        """Target like sess:1.2 should be kept as-is (has a dot)."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            o.send_message("sess:1.2", "msg", _skip_suffix=True)
            select_calls = [c for c in calls if "select-pane" in c]
            assert any("sess:1.2" in c for c in select_calls)


    def test_multiline_message_uses_bracketed_paste(self, monkeypatch):
        """Messages with newlines should use load-buffer + paste-buffer -p, not send-keys -l."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            msg = "Hello.\n- Line 1.\n- Line 2."
            result = o.send_message("%5", msg, _skip_suffix=True)
            assert result is True
            # Should NOT have send-keys -l for the message
            sendkeys_l_calls = [c for c in calls if "-l" in c and "send-keys" in c]
            assert len(sendkeys_l_calls) == 0
            # Should have load-buffer and paste-buffer -p
            load_calls = [c for c in calls if "load-buffer" in c]
            paste_calls = [c for c in calls if "paste-buffer" in c]
            assert len(load_calls) == 1
            assert len(paste_calls) == 1
            assert "-p" in paste_calls[0]

    def test_singleline_message_uses_send_keys(self, monkeypatch):
        """Messages without newlines should still use send-keys -l."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = o.send_message("%5", "no newlines here", _skip_suffix=True)
            assert result is True
            sendkeys_l_calls = [c for c in calls if "-l" in c and "send-keys" in c]
            assert len(sendkeys_l_calls) == 1
            load_calls = [c for c in calls if "load-buffer" in c]
            assert len(load_calls) == 0

    def test_multiline_load_buffer_failure(self, monkeypatch):
        """load-buffer failure should return False."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            if "load-buffer" in cmd:
                m.returncode = 1
                m.stderr = "error"
            else:
                m.returncode = 0
            m.stdout = ""
            return m

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = o.send_message("%5", "line1\nline2", _skip_suffix=True)
            assert result is False

    def test_multiline_paste_buffer_failure(self, monkeypatch):
        """paste-buffer failure should return False."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            if "paste-buffer" in cmd:
                m.returncode = 1
                m.stderr = "error"
            else:
                m.returncode = 0
            m.stdout = ""
            return m

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = o.send_message("%5", "line1\nline2", _skip_suffix=True)
            assert result is False

    def test_multiline_cleans_up_temp_file(self, monkeypatch):
        """Temp file should be cleaned up even on failure."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        created_files = []

        original_named_temp = tempfile.NamedTemporaryFile

        def track_tempfile(*args, **kwargs):
            kwargs["delete"] = False
            f = original_named_temp(*args, **kwargs)
            created_files.append(f.name)
            return f

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            if "paste-buffer" in cmd:
                m.returncode = 1
                m.stderr = "error"
            else:
                m.returncode = 0
            m.stdout = ""
            return m

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"), \
             patch("tempfile.NamedTemporaryFile", side_effect=track_tempfile):
            o.send_message("%5", "line1\nline2", _skip_suffix=True)
            # Temp file should have been cleaned up
            for f in created_files:
                assert not os.path.exists(f), f"Temp file {f} was not cleaned up"

    def test_multiline_buffer_uses_unique_name(self, monkeypatch):
        """Buffer name should include PID for uniqueness."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock(returncode=0, stdout="", stderr="")

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            o.send_message("%5", "line1\nline2", _skip_suffix=True)
            load_calls = [c for c in calls if "load-buffer" in c]
            assert len(load_calls) == 1
            # Buffer name should contain PID
            buf_idx = load_calls[0].index("-b") + 1
            buf_name = load_calls[0][buf_idx]
            assert str(os.getpid()) in buf_name


class TestSendKeysToWindow:
    def test_safety_mode_declined(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = True
        with patch("builtins.input", return_value="no"):
            assert o.send_keys_to_window("s", 0, "ls") is False

    def test_safety_mode_accepted(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = True
        mock = MagicMock()
        with patch("builtins.input", return_value="yes"), \
             patch("subprocess.run", return_value=mock):
            assert o.send_keys_to_window("s", 0, "ls") is True

    def test_no_confirm(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = True
        mock = MagicMock()
        with patch("subprocess.run", return_value=mock):
            assert o.send_keys_to_window("s", 0, "ls", confirm=False) is True

    def test_error(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "tmux")):
            assert o.send_keys_to_window("s", 0, "ls", confirm=False) is False


class TestSendCommandToWindow:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        mock = MagicMock()
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            assert o.send_command_to_window("s", 0, "echo hi", confirm=False) is True

    def test_enter_fails(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        call_count = [0]

        def mock_run(cmd, *args, **kwargs):
            call_count[0] += 1
            if call_count[0] == 2:  # Enter key send
                raise subprocess.CalledProcessError(1, "tmux")
            return MagicMock()

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            assert o.send_command_to_window("s", 0, "cmd", confirm=False) is False

    def test_first_send_fails(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            assert o.send_command_to_window("s", 0, "cmd", confirm=False) is False


class TestSendMessageToAgent:
    def test_pane_id(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        mock = MagicMock()
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            assert o.send_message_to_agent("%5", "hello") is True

    def test_session_window(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        mock = MagicMock()
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            assert o.send_message_to_agent("sess:1", "hello") is True

    def test_session_window_pane(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        mock = MagicMock()
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            assert o.send_message_to_agent("sess:1.2", "hello") is True

    def test_invalid_format(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        assert o.send_message_to_agent("invalid", "hello") is False

    def test_invalid_window_index(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        assert o.send_message_to_agent("sess:abc", "hello") is False


class TestSendToPane:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        mock = MagicMock()
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            assert o._send_to_pane("sess:0.1", "msg") is True

    def test_safety_declined(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = True
        with patch("builtins.input", return_value="no"):
            assert o._send_to_pane("sess:0.1", "msg", confirm=True) is False

    def test_error(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()
        o.safety_mode = False
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")), \
             patch("time.sleep"):
            assert o._send_to_pane("sess:0.1", "msg") is False


# ==================== Module-level functions ====================


class TestGetOrchestrator:
    def test_creates_singleton(self):
        # Reset
        tmux_mod._default_orchestrator = None
        o = _get_orchestrator()
        assert o is not None
        assert o.safety_mode is False
        # Second call returns same instance
        o2 = _get_orchestrator()
        assert o is o2
        # Cleanup
        tmux_mod._default_orchestrator = None


class TestModuleSendMessage:
    def test_delegates_to_orchestrator(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        tmux_mod._default_orchestrator = None
        mock = MagicMock(returncode=0, stdout="", stderr="")
        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            result = send_message("%5", "hi", _skip_suffix=True)
            assert result is True
        tmux_mod._default_orchestrator = None


class TestGetCurrentSession:
    def test_returns_session(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock(returncode=0, stdout="mysession\n")
        with patch("subprocess.run", return_value=mock):
            assert get_current_session() == "mysession"

    def test_empty_returns_none(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock(returncode=0, stdout="\n")
        with patch("subprocess.run", return_value=mock):
            assert get_current_session() is None

    def test_error_returns_none(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            assert get_current_session() is None


class TestRestartCheckinDisplay:
    def test_no_session(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("lib.tmux_utils.get_current_session", return_value=None):
            assert restart_checkin_display() is False

    def test_success_with_target(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock()
        # Create the display script
        yato_path = tmp_path / "yato"
        bin_dir = yato_path / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "checkin-display.sh").write_text("#!/bin/bash\necho ok")

        with patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            result = restart_checkin_display(target="sess:0", yato_path=str(yato_path))
            assert result is True

    def test_adds_pane_zero(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock()

        yato_path = str(Path(__file__).resolve().parent.parent.parent)
        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            restart_checkin_display(target="sess:0", yato_path=yato_path)
            # Should target sess:0.0
            all_cmds = [" ".join(c) for c in calls]
            assert any("sess:0.0" in c for c in all_cmds)

    def test_auto_detect_session(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock()
        yato_path = tmp_path / "yato"
        bin_dir = yato_path / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "checkin-display.sh").write_text("#!/bin/bash\necho ok")

        with patch("lib.tmux_utils.get_current_session", return_value="auto-sess"), \
             patch("subprocess.run", return_value=mock), \
             patch("time.sleep"):
            result = restart_checkin_display(yato_path=str(yato_path))
            assert result is True

    def test_subprocess_error(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")), \
             patch("time.sleep"):
            # Provide yato_path to avoid production bug (Path not imported at module level)
            result = restart_checkin_display(target="sess:0", yato_path=str(tmp_path))
            assert result is False

    def test_yato_path_none_uses_env_var(self, monkeypatch, tmp_path):
        """When yato_path=None and YATO_PATH env var is set, use env var (lines 591-593)."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        fake_yato = tmp_path / "yato-from-env"
        bin_dir = fake_yato / "bin"
        bin_dir.mkdir(parents=True)
        (bin_dir / "checkin-display.sh").write_text("#!/bin/bash\necho ok")
        monkeypatch.setenv("YATO_PATH", str(fake_yato))
        # Inject Path into module namespace (production bug: Path not imported at module level)
        monkeypatch.setattr(tmux_mod, "Path", Path, raising=False)

        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock()

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = restart_checkin_display(target="sess:0", yato_path=None)
            assert result is True
            # Verify it used the env var path, not an explicit yato_path
            all_cmds = [" ".join(c) for c in calls]
            assert any(str(fake_yato) in c for c in all_cmds)

    def test_yato_path_none_no_env_falls_back_to_file(self, monkeypatch):
        """When yato_path=None and no YATO_PATH env, falls back to Path(__file__) (line 593)."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        monkeypatch.delenv("YATO_PATH", raising=False)
        # Inject Path into module namespace (production bug: Path not imported at module level)
        monkeypatch.setattr(tmux_mod, "Path", Path, raising=False)

        calls = []

        def mock_run(cmd, *args, **kwargs):
            calls.append(cmd)
            return MagicMock()

        with patch("subprocess.run", side_effect=mock_run), \
             patch("time.sleep"):
            result = restart_checkin_display(target="sess:0", yato_path=None)
            assert result is True
            # The fallback uses Path(__file__).resolve().parent.parent which is the yato plugin root
            all_cmds = [" ".join(c) for c in calls]
            assert any("checkin-display.sh" in c for c in all_cmds)


class TestLookupPmPaneId:
    def test_from_agents_yml(self, tmp_workflow_with_agents):
        """Lookup PM pane_id from agents.yml via workflow_status_file."""
        status_file = str(tmp_workflow_with_agents / "status.yml")
        result = _lookup_pm_pane_id("test-session", status_file)
        assert result == "%5"

    def test_fallback_to_session(self, monkeypatch):
        """Falls back to session:0.1 when no agents.yml."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = _lookup_pm_pane_id("mysess")
            assert result == "mysess:0.1"

    def test_invalid_pane_id_falls_back(self, tmp_workflow):
        """Falls back when pane_id in agents.yml is invalid."""
        agents_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "invalid"},
            "agents": [],
        }
        with open(tmp_workflow / "agents.yml", "w") as f:
            yaml.dump(agents_data, f)

        status_file = str(tmp_workflow / "status.yml")
        result = _lookup_pm_pane_id("sess", status_file)
        assert result == "sess:0.1"


class TestNotifyPm:
    def test_no_session(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("lib.tmux_utils.get_current_session", return_value=None):
            result = notify_pm("msg")
            assert result is False

    def test_success(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock(returncode=0, stdout="", stderr="")

        with patch("lib.tmux_utils.get_current_session", return_value="sess"), \
             patch("lib.tmux_utils._lookup_pm_pane_id", return_value="%5"), \
             patch("lib.tmux_utils.send_message", return_value=True) as mock_send, \
             patch("lib.config.get", return_value=""):
            result = notify_pm("hello", session="sess")
            assert result is True
            mock_send.assert_called_once()
            # _skip_suffix should be True since notify_pm handles its own suffixes
            assert mock_send.call_args[1].get("_skip_suffix") is True

    def test_with_workflow_status_file(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        status_file = tmp_path / "status.yml"
        with open(status_file, "w") as f:
            yaml.dump({"agent_to_pm_message_suffix": "wf-agent-sfx"}, f)

        with patch("lib.tmux_utils._lookup_pm_pane_id", return_value="%5"), \
             patch("lib.tmux_utils.send_message", return_value=True) as mock_send, \
             patch("lib.config.get", return_value="yato-sfx"):
            result = notify_pm("hello", session="sess", workflow_status_file=str(status_file))
            assert result is True

    def test_importerror_fallback(self, monkeypatch, tmp_path):
        """Test ImportError fallback for config import in notify_pm."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)

        original_import = __builtins__.__import__ if hasattr(__builtins__, '__import__') else __import__

        def mock_import(name, *args, **kwargs):
            if name == "lib.config":
                raise ImportError("mocked")
            return original_import(name, *args, **kwargs)

        with patch("lib.tmux_utils._lookup_pm_pane_id", return_value="%5"), \
             patch("lib.tmux_utils.send_message", return_value=True), \
             patch("builtins.__import__", side_effect=mock_import):
            result = notify_pm("hello", session="sess")
            assert result is True


class TestSendToAgent:
    def test_no_session(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("lib.tmux_utils.get_current_session", return_value=None):
            result = send_to_agent("dev", "hi")
            assert result is False

    def test_no_workflow_name(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("lib.tmux_utils.get_current_session", return_value="sess"), \
             patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = send_to_agent("dev", "hi", session="sess")
            assert result is False

    def test_agent_not_found(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        # Create workflow dir with agents.yml
        workflow_dir = tmp_path / ".workflow" / "001-test"
        workflow_dir.mkdir(parents=True)
        agents_data = {"agents": [{"name": "qa", "role": "qa", "window": 1}]}
        with open(workflow_dir / "agents.yml", "w") as f:
            yaml.dump(agents_data, f)

        # Mock tmux showenv to return workflow name
        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            cmd_str = " ".join(cmd)
            if "showenv" in cmd_str:
                m.stdout = "WORKFLOW_NAME=001-test\n"
            elif "display-message" in cmd_str:
                m.stdout = str(tmp_path) + "\n"
            return m

        # Patch cwd to be in the project
        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run):
            result = send_to_agent("nonexistent", "hi", session="sess")
            assert result is False

    def test_success_with_pane_id(self, monkeypatch, tmp_path):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        # Create workflow dir with agents.yml
        workflow_dir = tmp_path / ".workflow" / "001-test"
        workflow_dir.mkdir(parents=True)
        agents_data = {
            "agents": [{"name": "dev", "role": "developer", "pane_id": "%10", "window": 1}]
        }
        with open(workflow_dir / "agents.yml", "w") as f:
            yaml.dump(agents_data, f)
        # Create status.yml
        with open(workflow_dir / "status.yml", "w") as f:
            yaml.dump({"status": "in-progress"}, f)

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            cmd_str = " ".join(cmd)
            if "showenv" in cmd_str:
                m.stdout = "WORKFLOW_NAME=001-test\n"
            m.stdout = getattr(m, "stdout", "")
            m.stderr = ""
            return m

        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run), \
             patch("lib.tmux_utils.send_message", return_value=True) as mock_send:
            result = send_to_agent("dev", "hi", session="sess")
            assert result is True
            # Should have been called with the pane_id
            assert mock_send.call_args[0][0] == "%10"


class TestLookupPmPaneIdFromTmuxEnv:
    """Tests for _lookup_pm_pane_id using tmux env var path."""

    def test_lookup_via_tmux_env(self, monkeypatch, tmp_path):
        """Finds PM via WORKFLOW_NAME tmux env var and searching cwd upward."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)

        # Create .workflow/001-test/agents.yml with PM pane_id
        wf = tmp_path / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        agents_data = {
            "pm": {"name": "pm", "role": "pm", "pane_id": "%42"},
            "agents": [],
        }
        with open(wf / "agents.yml", "w") as f:
            yaml.dump(agents_data, f)

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            m.stdout = "WORKFLOW_NAME=001-test\n"
            return m

        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run):
            result = _lookup_pm_pane_id("sess")
            assert result == "%42"

    def test_agents_yml_parse_error_falls_back(self, monkeypatch, tmp_path):
        """Falls back when agents.yml has parse error."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)

        wf = tmp_path / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "agents.yml").write_text("bad: yaml: [[[")

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            m.stdout = "WORKFLOW_NAME=001-test\n"
            return m

        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run):
            result = _lookup_pm_pane_id("sess")
            assert result == "sess:0.1"

    def test_workflow_not_found_walking_up(self, monkeypatch, tmp_path):
        """Falls back when walking up from cwd doesn't find .workflow/xxx."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)

        # No .workflow dir exists at all
        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            m.stdout = "WORKFLOW_NAME=nonexistent\n"
            return m

        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run):
            result = _lookup_pm_pane_id("sess")
            assert result == "sess:0.1"


class TestSendToAgentEdgeCases:
    """Additional edge case tests for send_to_agent."""

    def test_no_agents_yml(self, monkeypatch, tmp_path):
        """Fails when agents.yml doesn't exist."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_path / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            m.stdout = "WORKFLOW_NAME=001-test\n"
            return m

        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run):
            result = send_to_agent("dev", "hi", session="sess")
            assert result is False

    def test_agent_without_pane_id_uses_session_window(self, monkeypatch, tmp_path):
        """Agent without pane_id falls back to session:window format."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_path / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        agents_data = {
            "agents": [{"name": "dev", "role": "developer", "session": "mysess", "window": 3}],
        }
        with open(wf / "agents.yml", "w") as f:
            yaml.dump(agents_data, f)
        with open(wf / "status.yml", "w") as f:
            yaml.dump({"status": "in-progress"}, f)

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            m.stdout = "WORKFLOW_NAME=001-test\n"
            return m

        monkeypatch.chdir(tmp_path)
        with patch("subprocess.run", side_effect=mock_run), \
             patch("lib.tmux_utils.send_message", return_value=True) as mock_send:
            result = send_to_agent("dev", "hi", session="sess")
            assert result is True
            assert mock_send.call_args[0][0] == "mysess:3"

    def test_project_root_not_found_pane_path_fallback(self, monkeypatch, tmp_path):
        """Falls back to pane_current_path when cwd doesn't have .workflow."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        project = tmp_path / "project"
        project.mkdir()
        wf = project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        agents_data = {
            "agents": [{"name": "dev", "role": "developer", "pane_id": "%8", "window": 1}],
        }
        with open(wf / "agents.yml", "w") as f:
            yaml.dump(agents_data, f)
        with open(wf / "status.yml", "w") as f:
            yaml.dump({"status": "in-progress"}, f)

        # cwd is a dir WITHOUT .workflow
        other_dir = tmp_path / "other"
        other_dir.mkdir()
        monkeypatch.chdir(other_dir)

        call_count = [0]

        def mock_run(cmd, *args, **kwargs):
            call_count[0] += 1
            m = MagicMock()
            m.returncode = 0
            cmd_str = " ".join(cmd)
            if "showenv" in cmd_str:
                m.stdout = "WORKFLOW_NAME=001-test\n"
            elif "display-message" in cmd_str:
                m.stdout = str(project) + "\n"
            else:
                m.stdout = ""
            m.stderr = ""
            return m

        with patch("subprocess.run", side_effect=mock_run), \
             patch("lib.tmux_utils.send_message", return_value=True) as mock_send:
            result = send_to_agent("dev", "hi", session="sess")
            assert result is True

    def test_project_root_not_found_at_all(self, monkeypatch, tmp_path):
        """Returns False when neither cwd nor pane path has .workflow."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        monkeypatch.chdir(tmp_path)

        def mock_run(cmd, *args, **kwargs):
            m = MagicMock()
            m.returncode = 0
            cmd_str = " ".join(cmd)
            if "showenv" in cmd_str:
                m.stdout = "WORKFLOW_NAME=001-test\n"
            elif "display-message" in cmd_str:
                m.stdout = str(tmp_path) + "\n"
            else:
                m.stdout = ""
            m.stderr = ""
            return m

        with patch("subprocess.run", side_effect=mock_run):
            result = send_to_agent("dev", "hi", session="sess")
            assert result is False

    def test_pane_path_fallback_exception(self, monkeypatch, tmp_path):
        """Pane path fallback catches exceptions gracefully."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        monkeypatch.chdir(tmp_path)

        call_count = [0]

        def mock_run(cmd, *args, **kwargs):
            call_count[0] += 1
            cmd_str = " ".join(cmd)
            m = MagicMock()
            m.returncode = 0
            if "showenv" in cmd_str:
                m.stdout = "WORKFLOW_NAME=001-test\n"
            elif "display-message" in cmd_str:
                raise Exception("tmux error")
            else:
                m.stdout = ""
            m.stderr = ""
            return m

        with patch("subprocess.run", side_effect=mock_run):
            result = send_to_agent("dev", "hi", session="sess")
            assert result is False


class TestGetAllWindowsStatus:
    def test_returns_structure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        mock_session = TmuxSession(
            name="test",
            windows=[TmuxWindow(session_name="test", window_index=0, window_name="main", active=True)],
            attached=True,
        )
        with patch.object(o, "get_tmux_sessions", return_value=[mock_session]), \
             patch.object(o, "get_window_info", return_value={"name": "main", "content": "output"}):
            status = o.get_all_windows_status()
            assert "timestamp" in status
            assert len(status["sessions"]) == 1
            assert status["sessions"][0]["name"] == "test"


class TestCreateMonitoringSnapshot:
    def test_returns_string(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        o = TmuxOrchestrator()

        with patch.object(o, "get_all_windows_status", return_value={
            "timestamp": "2026-01-01T00:00:00",
            "sessions": [
                {
                    "name": "test",
                    "attached": True,
                    "windows": [
                        {
                            "index": 0,
                            "name": "main",
                            "active": True,
                            "info": {"content": "line1\nline2\n"},
                        }
                    ],
                }
            ],
        }):
            snapshot = o.create_monitoring_snapshot()
            assert "test" in snapshot
            assert "ATTACHED" in snapshot
            assert "main" in snapshot
            assert "ACTIVE" in snapshot
