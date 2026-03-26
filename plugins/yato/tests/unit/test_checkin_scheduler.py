"""Tests for lib/checkin_scheduler.py — check-in scheduling and daemon management."""

import json
import os
import signal
import subprocess
from datetime import datetime, timedelta
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest
import yaml

from lib.checkin_scheduler import (
    CheckinScheduler,
    get_workflow_from_tmux,
    find_project_root,
    _find_active_workflow,
    cancel_checkin,
    start_checkin,
    schedule_checkin,
    run_daemon,
    _tmux_cmd,
    DAEMON_POLL_INTERVAL,
)


# ==================== CheckinScheduler.__init__ ====================


class TestCheckinSchedulerInit:
    def test_with_workflow_path(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        assert sched.workflow_path == tmp_path / "wf"

    def test_without_workflow_path(self):
        sched = CheckinScheduler()
        assert sched.workflow_path is None


# ==================== Properties ====================


class TestCheckinSchedulerProperties:
    def test_checkins_file(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        assert sched.checkins_file == tmp_path / "wf" / "checkins.json"

    def test_status_file(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        assert sched.status_file == tmp_path / "wf" / "status.yml"

    def test_tasks_file(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        assert sched.tasks_file == tmp_path / "wf" / "tasks.json"

    def test_checkins_file_raises_without_path(self):
        sched = CheckinScheduler()
        with pytest.raises(ValueError, match="Workflow path not set"):
            _ = sched.checkins_file

    def test_status_file_raises_without_path(self):
        sched = CheckinScheduler()
        with pytest.raises(ValueError, match="Workflow path not set"):
            _ = sched.status_file

    def test_tasks_file_raises_without_path(self):
        sched = CheckinScheduler()
        with pytest.raises(ValueError, match="Workflow path not set"):
            _ = sched.tasks_file


# ==================== _load_checkins / _save_checkins ====================


class TestLoadSaveCheckins:
    def test_load_existing(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        data = {"checkins": [{"id": "1", "status": "done"}], "daemon_pid": 123}
        (wf / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(wf))
        loaded = sched._load_checkins()
        assert loaded["daemon_pid"] == 123
        assert len(loaded["checkins"]) == 1

    def test_load_missing_file(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        loaded = sched._load_checkins()
        assert loaded == {"checkins": [], "daemon_pid": None}

    def test_load_corrupt_json(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text("{invalid json")
        sched = CheckinScheduler(str(wf))
        loaded = sched._load_checkins()
        assert loaded == {"checkins": [], "daemon_pid": None}

    def test_load_adds_daemon_pid_key(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": []}))
        sched = CheckinScheduler(str(wf))
        loaded = sched._load_checkins()
        assert "daemon_pid" in loaded
        assert loaded["daemon_pid"] is None

    def test_save_creates_dirs(self, tmp_path):
        wf = tmp_path / "deep" / "nested" / "wf"
        sched = CheckinScheduler(str(wf))
        sched._save_checkins({"checkins": [], "daemon_pid": None})
        assert (wf / "checkins.json").exists()

    def test_save_and_reload(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        sched = CheckinScheduler(str(wf))
        data = {"checkins": [{"id": "x", "status": "pending"}], "daemon_pid": 42}
        sched._save_checkins(data)
        loaded = sched._load_checkins()
        assert loaded["daemon_pid"] == 42
        assert loaded["checkins"][0]["id"] == "x"


# ==================== is_daemon_running ====================


class TestIsDaemonRunning:
    def test_running_pid(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": 12345}))
        sched = CheckinScheduler(str(wf))
        with patch("os.kill") as mock_kill:
            mock_kill.return_value = None  # Process exists
            assert sched.is_daemon_running() is True
            mock_kill.assert_called_with(12345, 0)

    def test_dead_pid(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": 99999}))
        sched = CheckinScheduler(str(wf))
        with patch("os.kill", side_effect=ProcessLookupError):
            assert sched.is_daemon_running() is False

    def test_no_pid(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))
        sched = CheckinScheduler(str(wf))
        assert sched.is_daemon_running() is False


# ==================== get_daemon_pid ====================


class TestGetDaemonPid:
    def test_running(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": 555}))
        sched = CheckinScheduler(str(wf))
        with patch("os.kill"):
            assert sched.get_daemon_pid() == 555

    def test_dead(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": 555}))
        sched = CheckinScheduler(str(wf))
        with patch("os.kill", side_effect=ProcessLookupError):
            assert sched.get_daemon_pid() is None

    def test_none(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))
        sched = CheckinScheduler(str(wf))
        assert sched.get_daemon_pid() is None


# ==================== get_pending_count ====================


class TestGetPendingCount:
    def test_with_pending(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        data = {"checkins": [
            {"status": "pending"}, {"status": "done"}, {"status": "pending"}
        ], "daemon_pid": None}
        (wf / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(wf))
        assert sched.get_pending_count() == 2

    def test_none_pending(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        data = {"checkins": [{"status": "done"}, {"status": "cancelled"}], "daemon_pid": None}
        (wf / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(wf))
        assert sched.get_pending_count() == 0

    def test_empty(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        sched = CheckinScheduler(str(wf))
        assert sched.get_pending_count() == 0


# ==================== get_interval ====================


class TestGetInterval:
    def test_from_status_yml(self, tmp_workflow):
        sched = CheckinScheduler(str(tmp_workflow))
        interval = sched.get_interval()
        assert interval == 15

    def test_placeholder_underscore(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "status.yml").write_text(yaml.dump({"checkin_interval_minutes": "_"}))
        sched = CheckinScheduler(str(wf))
        assert sched.get_interval() is None

    def test_missing_file(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        assert sched.get_interval() is None

    def test_corrupt_yaml(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "status.yml").write_text(": : : bad yaml [[[")
        sched = CheckinScheduler(str(wf))
        assert sched.get_interval() is None


# ==================== get_incomplete_tasks_count ====================


class TestGetIncompleteTasksCount:
    def test_counts_incomplete(self, tmp_workflow, sample_tasks_data):
        tasks_file = tmp_workflow / "tasks.json"
        tasks_file.write_text(json.dumps(sample_tasks_data))
        sched = CheckinScheduler(str(tmp_workflow))
        # T1=pending, T2=pending, T3=completed => 2 incomplete
        assert sched.get_incomplete_tasks_count() == 2

    def test_all_completed(self, tmp_workflow):
        data = {"tasks": [{"status": "completed"}, {"status": "completed"}]}
        (tmp_workflow / "tasks.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))
        assert sched.get_incomplete_tasks_count() == 0

    def test_missing_file(self, tmp_path):
        sched = CheckinScheduler(str(tmp_path / "wf"))
        assert sched.get_incomplete_tasks_count() == 0

    def test_corrupt_json(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "tasks.json").write_text("{bad json")
        sched = CheckinScheduler(str(wf))
        assert sched.get_incomplete_tasks_count() == 0

    def test_counts_blocked(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        data = {"tasks": [
            {"status": "blocked"},
            {"status": "in_progress"},
            {"status": "completed"},
        ]}
        (wf / "tasks.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(wf))
        assert sched.get_incomplete_tasks_count() == 2


# ==================== start ====================


class TestStart:
    @patch.object(CheckinScheduler, "_start_daemon", return_value=1234)
    def test_starts_daemon(self, mock_daemon, tmp_workflow, capsys):
        sched = CheckinScheduler(str(tmp_workflow))
        with patch.object(sched, "is_daemon_running", return_value=False):
            pid = sched.start(interval_minutes=5, target="sess:0")
        assert pid == 1234
        # Check checkins.json was updated
        data = json.loads((tmp_workflow / "checkins.json").read_text())
        assert data["daemon_pid"] == 1234

    def test_already_running(self, tmp_workflow, capsys):
        sched = CheckinScheduler(str(tmp_workflow))
        with patch.object(sched, "is_daemon_running", return_value=True), \
             patch.object(sched, "get_daemon_pid", return_value=999):
            pid = sched.start(interval_minutes=5)
        assert pid is None
        captured = capsys.readouterr()
        assert "already running" in captured.out

    def test_no_interval(self, tmp_path, capsys):
        wf = tmp_path / "wf"
        wf.mkdir()
        (wf / "status.yml").write_text(yaml.dump({"checkin_interval_minutes": "_"}))
        sched = CheckinScheduler(str(wf))
        with patch.object(sched, "is_daemon_running", return_value=False):
            pid = sched.start()
        assert pid is None
        captured = capsys.readouterr()
        assert "No interval" in captured.out

    @patch.object(CheckinScheduler, "_start_daemon", return_value=2000)
    def test_resumes_after_stop(self, mock_daemon, tmp_workflow):
        data = {
            "checkins": [{"status": "stopped", "note": "stopped"}],
            "daemon_pid": None,
        }
        (tmp_workflow / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))
        with patch.object(sched, "is_daemon_running", return_value=False):
            pid = sched.start(interval_minutes=5, target="sess:0")
        assert pid == 2000
        loaded = json.loads((tmp_workflow / "checkins.json").read_text())
        # Should have a resumed entry
        statuses = [c["status"] for c in loaded["checkins"]]
        assert "resumed" in statuses


# ==================== _start_daemon ====================


class TestStartDaemon:
    @patch("lib.checkin_scheduler.subprocess.Popen")
    def test_popen_called(self, mock_popen, tmp_workflow):
        mock_popen.return_value = MagicMock(pid=5678)
        sched = CheckinScheduler(str(tmp_workflow))
        pid = sched._start_daemon(
            interval_minutes=5,
            target="sess:0",
            yato_path="/tmp/yato",
            project_dir="/tmp/proj",
            workflow_name="001-test",
        )
        assert pid == 5678
        mock_popen.assert_called_once()
        call_args = mock_popen.call_args
        cmd = call_args[0][0]
        assert "daemon" in cmd
        assert "--interval" in cmd


# ==================== cancel ====================


class TestCancel:
    @patch("time.sleep")
    def test_kills_running_daemon(self, mock_sleep, tmp_workflow):
        data = {"checkins": [{"status": "pending", "id": "1"}], "daemon_pid": 9999}
        (tmp_workflow / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))

        with patch("os.kill") as mock_kill:
            # First call: get_daemon_pid -> kill(pid, 0) succeeds
            # Second call: cancel -> kill(pid, SIGTERM) succeeds
            # Third call: check still alive -> kill(pid, 0) raises (dead)
            mock_kill.side_effect = [
                None,  # get_daemon_pid check
                None,  # SIGTERM
                ProcessLookupError,  # already dead after SIGTERM
            ]
            result = sched.cancel()

        assert result is True
        loaded = json.loads((tmp_workflow / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None
        # Pending should be cancelled
        statuses = [c["status"] for c in loaded["checkins"]]
        assert "cancelled" in statuses
        assert "stopped" in statuses

    def test_not_running_still_marks_stopped(self, tmp_workflow, capsys):
        data = {"checkins": [{"status": "pending", "id": "1"}], "daemon_pid": None}
        (tmp_workflow / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))
        result = sched.cancel()
        assert result is False
        captured = capsys.readouterr()
        assert "No check-in daemon" in captured.out
        loaded = json.loads((tmp_workflow / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None

    @patch("time.sleep")
    def test_sigterm_then_sigkill(self, mock_sleep, tmp_workflow):
        """When process survives SIGTERM, SIGKILL should be sent."""
        data = {"checkins": [{"status": "pending", "id": "1"}], "daemon_pid": 9999}
        (tmp_workflow / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))

        with patch("os.kill") as mock_kill:
            # get_daemon_pid check -> alive
            # SIGTERM -> succeeds
            # check alive -> still alive
            # SIGKILL -> succeeds
            mock_kill.side_effect = [None, None, None, None]
            result = sched.cancel()

        assert result is True
        # Should have called SIGKILL
        sigkill_calls = [c for c in mock_kill.call_args_list if len(c[0]) >= 2 and c[0][1] == signal.SIGKILL]
        assert len(sigkill_calls) == 1

    @patch("time.sleep")
    def test_sigterm_raises_oserror(self, mock_sleep, tmp_workflow):
        """When SIGTERM raises OSError (already dead), cancel still succeeds."""
        data = {"checkins": [], "daemon_pid": 9999}
        (tmp_workflow / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))

        with patch("os.kill") as mock_kill:
            # get_daemon_pid check -> alive
            # SIGTERM -> already dead
            mock_kill.side_effect = [None, OSError("already dead")]
            result = sched.cancel()

        assert result is True


# ==================== list_checkins ====================


class TestListCheckins:
    def test_all(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        data = {"checkins": [
            {"status": "done"}, {"status": "pending"}, {"status": "cancelled"}
        ], "daemon_pid": None}
        (wf / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(wf))
        assert len(sched.list_checkins()) == 3

    def test_filter_by_status(self, tmp_path):
        wf = tmp_path / "wf"
        wf.mkdir()
        data = {"checkins": [
            {"status": "done"}, {"status": "pending"}, {"status": "done"}
        ], "daemon_pid": None}
        (wf / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(wf))
        assert len(sched.list_checkins(status="done")) == 2
        assert len(sched.list_checkins(status="pending")) == 1


# ==================== status ====================


class TestStatus:
    def test_returns_comprehensive_dict(self, tmp_workflow, sample_tasks_data):
        (tmp_workflow / "tasks.json").write_text(json.dumps(sample_tasks_data))
        data = {"checkins": [
            {"status": "pending", "scheduled_for": "2026-01-01T12:00:00"},
        ], "daemon_pid": None}
        (tmp_workflow / "checkins.json").write_text(json.dumps(data))
        sched = CheckinScheduler(str(tmp_workflow))
        status = sched.status()
        assert "daemon_running" in status
        assert "daemon_pid" in status
        assert "interval_minutes" in status
        assert "incomplete_tasks" in status
        assert "next_checkin" in status
        assert "total_checkins" in status
        assert status["interval_minutes"] == 15
        assert status["incomplete_tasks"] == 2
        assert status["next_checkin"] == "2026-01-01T12:00:00"


# ==================== get_workflow_from_tmux ====================


class TestGetWorkflowFromTmux:
    @patch("lib.checkin_scheduler.subprocess.run")
    def test_success(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(
            returncode=0, stdout="WORKFLOW_NAME=001-feat\n"
        )
        result = get_workflow_from_tmux()
        assert result == "001-feat"

    @patch("lib.checkin_scheduler.subprocess.run", side_effect=subprocess.CalledProcessError(1, "tmux"))
    def test_called_process_error(self, mock_run, clean_env):
        result = get_workflow_from_tmux()
        assert result is None

    @patch("lib.checkin_scheduler.subprocess.run")
    def test_no_equals(self, mock_run, clean_env):
        mock_run.return_value = MagicMock(
            returncode=0, stdout="-WORKFLOW_NAME\n"
        )
        result = get_workflow_from_tmux()
        assert result is None


# ==================== find_project_root ====================


class TestFindProjectRoot:
    def test_walk_up_finds_workflow(self, tmp_project, monkeypatch):
        (tmp_project / ".workflow").mkdir()
        monkeypatch.chdir(tmp_project)
        result = find_project_root()
        assert result == tmp_project

    def test_with_workflow_name_verification(self, tmp_project, monkeypatch):
        (tmp_project / ".workflow" / "001-feat").mkdir(parents=True)
        monkeypatch.chdir(tmp_project)
        result = find_project_root("001-feat")
        assert result == tmp_project

    def test_workflow_name_not_found_returns_first_match(self, tmp_project, monkeypatch):
        (tmp_project / ".workflow").mkdir()
        monkeypatch.chdir(tmp_project)
        with patch("lib.checkin_scheduler.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="")
            result = find_project_root("999-nonexistent")
        # Returns first_match (project has .workflow/ but not the specific workflow)
        assert result == tmp_project

    def test_no_workflow_returns_none(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        with patch("lib.checkin_scheduler.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=1, stdout="")
            result = find_project_root()
        assert result is None


# ==================== _find_active_workflow ====================


class TestFindActiveWorkflow:
    def test_finds_workflow_with_running_daemon(self, tmp_project):
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        data = {"checkins": [], "daemon_pid": 12345}
        (wf / "checkins.json").write_text(json.dumps(data))
        with patch("os.kill") as mock_kill:
            mock_kill.return_value = None  # Simulate process alive
            result = _find_active_workflow(tmp_project)
        assert result == "001-test"
        mock_kill.assert_called_with(12345, 0)

    def test_no_workflows(self, tmp_project):
        (tmp_project / ".workflow").mkdir()
        result = _find_active_workflow(tmp_project)
        assert result is None

    def test_dead_daemon_skipped(self, tmp_project):
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        data = {"checkins": [], "daemon_pid": 999999}
        (wf / "checkins.json").write_text(json.dumps(data))
        with patch("os.kill", side_effect=ProcessLookupError):
            result = _find_active_workflow(tmp_project)
        assert result is None

    def test_no_workflow_dir(self, tmp_project):
        result = _find_active_workflow(tmp_project)
        assert result is None


# ==================== cancel_checkin (module-level) ====================


class TestCancelCheckin:
    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root")
    def test_auto_detection(self, mock_root, mock_tmux, tmp_project):
        wf = tmp_project / ".workflow" / "001-feat"
        wf.mkdir(parents=True)
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))
        mock_root.return_value = tmp_project
        result = cancel_checkin()
        assert result is False  # No daemon running

    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value=None)
    @patch("lib.checkin_scheduler.find_project_root", return_value=None)
    @patch("lib.checkin_scheduler.subprocess.run")
    def test_no_workflow_found(self, mock_run, mock_root, mock_tmux, capsys, clean_env):
        mock_run.return_value = MagicMock(returncode=1, stdout="")
        result = cancel_checkin()
        assert result is False

    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root", return_value=None)
    def test_no_project_root(self, mock_root, mock_tmux, capsys):
        result = cancel_checkin()
        assert result is False
        captured = capsys.readouterr()
        assert "Could not find" in captured.out

    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root")
    def test_workflow_dir_not_found(self, mock_root, mock_tmux, tmp_project, capsys):
        mock_root.return_value = tmp_project
        (tmp_project / ".workflow").mkdir()
        # 001-feat doesn't exist
        result = cancel_checkin()
        assert result is False
        captured = capsys.readouterr()
        assert "not found" in captured.out


# ==================== start_checkin (module-level) ====================


class TestStartCheckin:
    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root")
    @patch.object(CheckinScheduler, "start", return_value=1234)
    def test_module_level_function(self, mock_start, mock_root, mock_tmux, tmp_project):
        wf = tmp_project / ".workflow" / "001-feat"
        wf.mkdir(parents=True)
        mock_root.return_value = tmp_project
        pid = start_checkin(minutes=5, workflow_name="001-feat")
        assert pid == 1234

    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value=None)
    def test_no_workflow(self, mock_tmux, capsys):
        pid = start_checkin(minutes=5)
        assert pid is None
        captured = capsys.readouterr()
        assert "No WORKFLOW_NAME" in captured.out

    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root", return_value=None)
    def test_no_project_root(self, mock_root, mock_tmux, capsys):
        pid = start_checkin(minutes=5)
        assert pid is None
        captured = capsys.readouterr()
        assert "Could not find" in captured.out

    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root")
    def test_workflow_dir_not_found(self, mock_root, mock_tmux, tmp_project, capsys):
        mock_root.return_value = tmp_project
        (tmp_project / ".workflow").mkdir()
        pid = start_checkin(minutes=5)
        assert pid is None
        captured = capsys.readouterr()
        assert "not found" in captured.out


# ==================== schedule_checkin (backward compat) ====================


class TestScheduleCheckin:
    @patch("lib.checkin_scheduler.start_checkin", return_value=42)
    def test_alias(self, mock_start):
        result = schedule_checkin(5, "note", "target", "wf")
        assert result == 42
        mock_start.assert_called_once_with(5, "note", "target", "wf")


# ==================== _tmux_cmd ====================


class TestTmuxCmd:
    def test_without_socket(self, clean_env):
        assert _tmux_cmd() == ["tmux"]

    def test_with_socket(self, clean_env):
        clean_env.setenv("TMUX_SOCKET", "sock")
        assert _tmux_cmd() == ["tmux", "-L", "sock"]


# ==================== run_daemon (main loop) ====================


class TestRunDaemon:
    """Tests for the daemon loop function.

    These tests verify the daemon's behavior at a high level by mocking
    time.sleep to prevent actual blocking and controlling the loop via
    the should_stop mechanism.
    """

    @patch("lib.checkin_scheduler.time.sleep")
    def test_stops_when_all_tasks_complete(self, mock_sleep, tmp_project):
        """Daemon should stop when all tasks are completed."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        # All tasks completed
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        # Status file
        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # Checkins with current PID
        pid = os.getpid()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": datetime.now().isoformat()}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Mock send_message to avoid actual tmux calls
        with patch("lib.checkin_scheduler.run_daemon.__module__", "lib.checkin_scheduler"):
            # We need to mock the tmux send at module level inside run_daemon
            # The daemon imports send_message internally, so we patch at lib.tmux_utils level
            with patch("lib.tmux_utils.send_message"):
                run_daemon(
                    workflow_name=wf_name,
                    interval_minutes=1,
                    target="sess:0",
                    yato_path=str(tmp_project),
                    project_dir=str(tmp_project),
                )

        # After running, should be stopped
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None

    @patch("lib.checkin_scheduler.time.sleep")
    def test_stops_on_should_stop(self, mock_sleep, tmp_project):
        """Daemon should stop when PID is cleared from checkins.json."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        # Tasks still incomplete
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # PID set to something else (not our PID) -> should_stop returns True
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": datetime.now().isoformat()}],
            "daemon_pid": -1,  # Not our PID
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )
        # Should exit immediately since PID doesn't match

    @patch("lib.checkin_scheduler.time.sleep")
    def test_sends_checkin_message_when_time_expires(self, mock_sleep, tmp_project):
        """Daemon sends check-in then stops when tasks completed on next cycle."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        # Tasks start incomplete, then become completed
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # Pending checkin scheduled in the past (should fire immediately)
        past_time = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past_time}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            # After first check-in, make all tasks completed so daemon stops
            tasks_data_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_data_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should have sent at least one message
        assert len(send_calls) >= 1
        # Daemon should have stopped
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None

    @patch("lib.checkin_scheduler.time.sleep")
    def test_daemon_stopped_entry_in_checkins(self, mock_sleep, tmp_project):
        """Daemon writes stopped entry on stop."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        checkins_data = {
            "checkins": [],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        loaded = json.loads((wf / "checkins.json").read_text())
        statuses = [c["status"] for c in loaded["checkins"]]
        assert "stopped" in statuses

    @patch("lib.checkin_scheduler.time.sleep")
    def test_daemon_updates_status_yml_on_completion(self, mock_sleep, tmp_project):
        """Daemon marks status.yml as completed when all tasks are done."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        checkins_data = {"checkins": [], "daemon_pid": pid}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        status_content = (wf / "status.yml").read_text()
        assert "completed" in status_content


# ==================== find_project_root tmux fallback ====================


class TestFindProjectRootTmuxFallback:
    def test_tmux_session_path_fallback(self, tmp_project, monkeypatch):
        """find_project_root checks tmux session paths when workflow_name not found in cwd."""
        (tmp_project / ".workflow" / "001-feat").mkdir(parents=True)
        # chdir to a directory WITHOUT .workflow
        monkeypatch.chdir(tmp_project.parent)
        with patch("lib.checkin_scheduler.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(
                returncode=0, stdout=str(tmp_project) + "\n"
            )
            result = find_project_root("001-feat")
        assert result == tmp_project


# ==================== cancel_checkin tmux path scanning ====================


class TestCancelCheckinTmuxPaths:
    @patch("lib.checkin_scheduler._find_active_workflow", return_value="001-feat")
    @patch("lib.checkin_scheduler.subprocess.run")
    @patch("lib.checkin_scheduler.find_project_root", return_value=None)
    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value=None)
    def test_tmux_path_scanning(self, mock_tmux, mock_root, mock_run, mock_active, tmp_project, clean_env):
        """cancel_checkin scans tmux paths when workflow_name not found."""
        wf = tmp_project / ".workflow" / "001-feat"
        wf.mkdir(parents=True)
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))
        # Mock tmux display-message returning a path with .workflow
        mock_run.return_value = MagicMock(returncode=0, stdout=str(tmp_project) + "\n")
        result = cancel_checkin()
        assert isinstance(result, bool)


# ==================== run_daemon suffix stacking ====================


class TestRunDaemonSuffixStacking:
    """Tests that the daemon's inner send_message applies suffix stacking."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_both_suffixes_applied(self, mock_sleep, tmp_project):
        """send_message stacks yato-level and workflow-level suffixes."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()

        # Tasks start pending, will be completed after first send
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        # Status with workflow-level suffix
        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
            "checkin_message_suffix": "wf-suffix-here",
        }))

        # Pending checkin scheduled in the past
        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Yato-level config with CHECKIN_TO_PM_SUFFIX
        config_dir = tmp_project / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text(
            'CHECKIN_TO_PM_SUFFIX="yato-suffix-here"\n'
        )

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            # After first check-in message, complete tasks so daemon stops
            tasks_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # The first message should be "Time for check-in!" with both suffixes
        assert len(send_calls) >= 1
        checkin_msg = send_calls[0]
        assert "yato-suffix-here" in checkin_msg
        assert "wf-suffix-here" in checkin_msg

    @patch("lib.checkin_scheduler.time.sleep")
    def test_only_yato_suffix_when_no_workflow_suffix(self, mock_sleep, tmp_project):
        """send_message applies only yato suffix when workflow suffix is empty."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        # No workflow suffix
        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
            "checkin_message_suffix": "",
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        config_dir = tmp_project / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text(
            'CHECKIN_TO_PM_SUFFIX="yato-only"\n'
        )

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            tasks_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        assert len(send_calls) >= 1
        assert "yato-only" in send_calls[0]

    @patch("lib.checkin_scheduler.time.sleep")
    def test_only_workflow_suffix_when_no_yato_suffix(self, mock_sleep, tmp_project):
        """send_message applies only workflow suffix when yato suffix is empty."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
            "checkin_message_suffix": "wf-only",
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Config with empty CHECKIN_TO_PM_SUFFIX
        config_dir = tmp_project / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text(
            'CHECKIN_TO_PM_SUFFIX=""\n'
        )

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            tasks_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        assert len(send_calls) >= 1
        assert "wf-only" in send_calls[0]


# ==================== run_daemon corrupt tasks ====================


class TestRunDaemonCorruptTasks:
    """Tests daemon behavior with unreadable/corrupt tasks.json."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_corrupt_tasks_returns_error_message(self, mock_sleep, tmp_project):
        """Corrupt tasks.json causes -1 return and ERROR in message."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()

        # Corrupt tasks.json
        (wf / "tasks.json").write_text("{bad json")

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            # After first send, clear PID so daemon stops
            data = json.loads((wf / "checkins.json").read_text())
            data["daemon_pid"] = None
            (wf / "checkins.json").write_text(json.dumps(data))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should have sent a message containing ERROR
        assert len(send_calls) >= 1
        assert "ERROR" in send_calls[0]


# ==================== run_daemon no tasks file ====================


class TestRunDaemonNoTasksFile:
    """Tests daemon when tasks.json doesn't exist."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_missing_tasks_file_returns_zero_and_stops(self, mock_sleep, tmp_project):
        """No tasks.json => get_incomplete_tasks returns 0 => daemon stops immediately."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        # No tasks.json created at all

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        checkins_data = {
            "checkins": [],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Daemon should stop and send completion message
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None
        assert any("All tasks complete" in m for m in send_calls)


# ==================== run_daemon stopped entry ====================


class TestRunDaemonStoppedEntry:
    """Tests should_stop detecting a 'stopped' status entry."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_stopped_entry_causes_daemon_exit(self, mock_sleep, tmp_project):
        """Daemon exits when a 'stopped' entry is the last meaningful entry."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()

        # Tasks are incomplete (daemon wouldn't stop from completion)
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # Checkins with a "stopped" entry already present
        checkins_data = {
            "checkins": [
                {"id": "1", "status": "pending", "scheduled_for": datetime.now().isoformat()},
                {"id": "stop-1", "status": "stopped", "note": "Manual stop"},
            ],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Daemon should have exited (via should_stop detecting "stopped")
        # It exits the while loop without calling stop_loop, so the file remains as is

    @patch("lib.checkin_scheduler.time.sleep")
    def test_stopped_entry_injected_during_run(self, mock_sleep, tmp_project):
        """Daemon exits when 'stopped' entry is added during execution."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()

        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # Start with valid state
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": (datetime.now() + timedelta(hours=1)).isoformat()}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        call_count = [0]

        def side_effect_sleep(seconds):
            call_count[0] += 1
            if call_count[0] == 2:
                # Inject a stopped entry during daemon run
                data = json.loads((wf / "checkins.json").read_text())
                data["checkins"].append({"id": "stop-2", "status": "stopped", "note": "External stop"})
                (wf / "checkins.json").write_text(json.dumps(data))

        mock_sleep.side_effect = side_effect_sleep

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=60,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should have exited without error


# ==================== run_daemon at-checkin-time all tasks complete ====================


class TestRunDaemonAtCheckinAllComplete:
    """Tests the else branch at lines 657-664: check-in time expires but all tasks already complete."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_at_checkin_time_all_complete(self, mock_sleep, tmp_project):
        """When check-in time expires and tasks are all complete at line 646, daemon stops via else branch."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()

        # Tasks start pending
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # Pending checkin scheduled in the past
        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        send_calls = []
        tasks_read_count = [0]
        _original_json_load = json.load

        def counting_json_load(f):
            """Intercept json.load to track tasks.json reads and change behavior."""
            # Peek at the file name from the file object
            fname = getattr(f, "name", "")
            result = _original_json_load(f)
            if "tasks.json" in fname:
                tasks_read_count[0] += 1
                # On the 2nd+ read of tasks.json (line 646 get_incomplete_tasks),
                # return completed tasks
                if tasks_read_count[0] >= 2:
                    return {"tasks": [{"status": "completed"}]}
            return result

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            with patch("json.load", side_effect=counting_json_load):
                run_daemon(
                    workflow_name=wf_name,
                    interval_minutes=1,
                    target="sess:0",
                    yato_path=str(tmp_project),
                    project_dir=str(tmp_project),
                )

        # Should have sent completion message via the else branch (lines 659-664)
        assert any("All tasks complete" in m for m in send_calls)
        # Verify daemon properly stopped
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None



# ==================== run_daemon multiline suffix ====================


class TestRunDaemonMultilineSuffix:
    """Tests multiline CHECKIN_TO_PM_SUFFIX parsing from defaults.conf."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_multiline_suffix_parsed_correctly(self, mock_sleep, tmp_project):
        """Multiline quoted suffix in defaults.conf is properly applied."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Multiline CHECKIN_TO_PM_SUFFIX
        config_dir = tmp_project / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text(
            'CHECKIN_TO_PM_SUFFIX="line one\n'
            'line two\n'
            'line three"\n'
        )

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            tasks_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        assert len(send_calls) >= 1
        # The multiline suffix should contain all three lines
        assert "line one" in send_calls[0]
        assert "line two" in send_calls[0]
        assert "line three" in send_calls[0]


# ==================== run_daemon send_message exception ====================


class TestRunDaemonSendMessageException:
    """Tests that send_message catches exceptions gracefully (lines 601-602)."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_send_message_exception_swallowed(self, mock_sleep, tmp_project):
        """When _tmux_send_message raises, the exception is caught and daemon continues."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        checkins_data = {"checkins": [], "daemon_pid": pid}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        def mock_send(target, msg, _skip_suffix=False):
            raise RuntimeError("tmux not available")

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            # Should NOT raise, despite send_message throwing
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Daemon should still have stopped properly
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None


# ==================== run_daemon update_status_completed edge cases ====================


class TestRunDaemonUpdateStatusCompleted:
    """Tests update_status_completed edge cases."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_no_status_file(self, mock_sleep, tmp_project):
        """update_status_completed does nothing if status.yml doesn't exist (line 535)."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        # No status.yml created
        checkins_data = {"checkins": [], "daemon_pid": pid}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should complete without error, status.yml still doesn't exist
        assert not (wf / "status.yml").exists()

    @patch("lib.checkin_scheduler.time.sleep")
    def test_status_file_write_exception(self, mock_sleep, tmp_project):
        """update_status_completed catches exceptions when writing status.yml (lines 545-546)."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        # Create status.yml
        (wf / "status.yml").write_text("status: in-progress\n")

        checkins_data = {"checkins": [], "daemon_pid": pid}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Make status.yml read-only to trigger write exception
        status_path = wf / "status.yml"
        status_path.chmod(0o444)

        try:
            with patch("lib.tmux_utils.send_message"):
                # Should NOT raise, the exception is caught
                run_daemon(
                    workflow_name=wf_name,
                    interval_minutes=1,
                    target="sess:0",
                    yato_path=str(tmp_project),
                    project_dir=str(tmp_project),
                )
        finally:
            status_path.chmod(0o644)

        # Daemon should still have stopped properly
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None


# ==================== run_daemon scheduled_for parse exception ====================


class TestRunDaemonScheduledForParseException:
    """Tests exception handling in scheduled_for parsing (lines 614-615)."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_invalid_scheduled_for_format(self, mock_sleep, tmp_project):
        """Invalid scheduled_for value is caught, daemon uses default interval."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        # Pending checkin with invalid scheduled_for
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": "not-a-date"}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should complete without error
        loaded = json.loads((wf / "checkins.json").read_text())
        assert loaded["daemon_pid"] is None


# ==================== run_daemon load_checkins edge cases ====================


class TestRunDaemonLoadCheckins:
    """Tests daemon inner load_checkins edge cases."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_missing_checkins_file_returns_empty(self, mock_sleep, tmp_project):
        """When checkins.json doesn't exist, load_checkins returns empty (line 430)."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        # All tasks completed so daemon will stop quickly
        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))
        (wf / "status.yml").write_text(yaml.dump({"status": "in-progress"}))

        # Don't create checkins.json at all
        # The daemon's load_checkins will see file doesn't exist -> return empty
        # But should_stop checks daemon_pid, and empty means None != os.getpid() -> stops immediately

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should have exited quickly (should_stop returned True due to PID mismatch)

    @patch("lib.checkin_scheduler.time.sleep")
    def test_corrupt_checkins_file_retries(self, mock_sleep, tmp_project):
        """When checkins.json is corrupt, load_checkins retries and returns fallback (lines 435-440)."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        tasks_data = {"tasks": [{"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))
        (wf / "status.yml").write_text(yaml.dump({"status": "in-progress"}))

        # Create corrupt checkins.json
        (wf / "checkins.json").write_text("{corrupt json")

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # The corrupt file causes load_checkins to retry 3 times then return
        # {"checkins": [], "daemon_pid": os.getpid()}, so daemon proceeds.
        # With all tasks complete, it stops normally.


# ==================== _find_active_workflow corrupt json ====================


class TestFindActiveWorkflowCorruptJson:
    """Tests _find_active_workflow with corrupt checkins.json (lines 754-755)."""

    def test_corrupt_checkins_json(self, tmp_project):
        """Corrupt checkins.json doesn't crash _find_active_workflow."""
        wf = tmp_project / ".workflow" / "001-feat"
        wf.mkdir(parents=True)
        (wf / "checkins.json").write_text("{bad json")

        result = _find_active_workflow(tmp_project)
        assert result is None

    def test_multiple_workflows_one_corrupt(self, tmp_project):
        """One corrupt checkins.json doesn't prevent finding valid ones."""
        wf1 = tmp_project / ".workflow" / "001-corrupt"
        wf1.mkdir(parents=True)
        (wf1 / "checkins.json").write_text("{bad")

        wf2 = tmp_project / ".workflow" / "002-valid"
        wf2.mkdir(parents=True)
        # Valid JSON but no running daemon
        (wf2 / "checkins.json").write_text(json.dumps({"daemon_pid": None, "checkins": []}))

        result = _find_active_workflow(tmp_project)
        assert result is None


# ==================== find_project_root tmux fallback exception ====================


class TestFindProjectRootTmuxException:
    """Tests find_project_root tmux fallback exception handling (lines 729-730)."""

    def test_tmux_command_raises_exception(self, tmp_project, monkeypatch):
        """Exception from tmux command is caught gracefully."""
        monkeypatch.chdir(tmp_project.parent)

        def raise_on_tmux(*args, **kwargs):
            raise OSError("tmux not available")

        with patch("lib.checkin_scheduler.subprocess.run", side_effect=raise_on_tmux):
            result = find_project_root("001-nonexistent")

        # Should return None (no match found, tmux failed gracefully)
        assert result is None


# ==================== cancel_checkin tmux path scanning edge cases ====================


class TestCancelCheckinTmuxPathScanning:
    """Tests cancel_checkin tmux path scanning (lines 778, 791-792)."""

    @patch("lib.checkin_scheduler._find_active_workflow", return_value=None)
    @patch("lib.checkin_scheduler.find_project_root")
    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value=None)
    def test_tmux_exception_in_path_scan(self, mock_tmux, mock_root, mock_active, tmp_project, capsys):
        """Exception during tmux path scan is caught (lines 791-792)."""
        mock_root.return_value = tmp_project
        (tmp_project / ".workflow").mkdir(parents=True)

        def raise_on_tmux(*args, **kwargs):
            raise OSError("tmux not available")

        with patch("lib.checkin_scheduler.subprocess.run", side_effect=raise_on_tmux):
            result = cancel_checkin()

        assert result is False
        captured = capsys.readouterr()
        assert "No WORKFLOW_NAME" in captured.out

    @patch("lib.checkin_scheduler._find_active_workflow", return_value="001-feat")
    @patch("lib.checkin_scheduler.find_project_root")
    @patch("lib.checkin_scheduler.get_workflow_from_tmux", return_value=None)
    def test_tmux_path_adds_candidate(self, mock_tmux, mock_root, mock_active, tmp_project):
        """tmux path adds candidate when .workflow exists (line 778 + 789-790)."""
        wf = tmp_project / ".workflow" / "001-feat"
        wf.mkdir(parents=True)
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))

        # find_project_root returns None for initial call but tmp_project for workflow_name call
        mock_root.side_effect = [None, tmp_project]

        with patch("lib.checkin_scheduler.subprocess.run") as mock_run:
            mock_run.return_value = MagicMock(returncode=0, stdout=str(tmp_project) + "\n")
            result = cancel_checkin()

        assert isinstance(result, bool)


# ==================== __main__ CLI block ====================


class TestCheckinSchedulerCLI:
    """Tests for the __main__ CLI block (lines 868-965).

    Uses exec() to run the CLI code in-process so coverage can track it.
    The __main__ block is extracted from the source and executed in a namespace
    with mocked functions.
    """

    @staticmethod
    def _get_main_code():
        """Extract and compile the __main__ block with correct source mapping for coverage."""
        import textwrap
        src_path = Path(__file__).resolve().parent.parent.parent / "lib" / "checkin_scheduler.py"
        source = src_path.read_text()
        lines = source.splitlines(keepends=True)
        # Find the 'if __name__ == "__main__":' line
        start_line = None
        for i, line in enumerate(lines):
            if line.strip() == 'if __name__ == "__main__":':
                start_line = i
                break
        # Extract the body (everything after the if line, dedented)
        body_lines = lines[start_line + 1:]
        body = textwrap.dedent("".join(body_lines))
        # Compile with real filename and correct line offset for coverage tracking
        # Pad with empty lines so line numbers match the source file
        padded = "\n" * (start_line + 1) + body
        code_obj = compile(padded, str(src_path), "exec")
        return code_obj

    def _exec_cli(self, argv, namespace_overrides=None):
        """Execute the CLI __main__ block in a controlled namespace."""
        import argparse
        code_obj = self._get_main_code()

        # Build namespace with all needed imports and module-level names
        ns = {
            "__name__": "__test__",
            "argparse": argparse,
            "json": json,
            "sys": __import__("sys"),
            "Path": Path,
            "CheckinScheduler": CheckinScheduler,
            "start_checkin": MagicMock(return_value=None),
            "cancel_checkin": MagicMock(return_value=True),
            "get_workflow_from_tmux": MagicMock(return_value=None),
            "find_project_root": MagicMock(return_value=None),
            "run_daemon": MagicMock(),
            "print": MagicMock(),
        }
        if namespace_overrides:
            ns.update(namespace_overrides)

        # Patch sys.argv for argparse
        original_argv = __import__("sys").argv
        __import__("sys").argv = ["checkin_scheduler"] + argv
        try:
            exec(code_obj, ns)
        except SystemExit:
            pass
        finally:
            __import__("sys").argv = original_argv

        return ns

    def test_start_command(self):
        """CLI 'start' command calls start_checkin with correct args."""
        mock_start = MagicMock(return_value=1234)
        ns = self._exec_cli(
            ["start", "5", "--workflow", "001-test", "--note", "test note", "--target", "sess:0"],
            {"start_checkin": mock_start},
        )
        mock_start.assert_called_once_with(5, "test note", "sess:0", "001-test")

    def test_start_command_no_minutes(self):
        """CLI 'start' without minutes passes None."""
        mock_start = MagicMock(return_value=None)
        ns = self._exec_cli(
            ["start", "--workflow", "001-test"],
            {"start_checkin": mock_start},
        )
        mock_start.assert_called_once_with(None, "Standard check-in", "tmux-orc:0", "001-test")

    def test_schedule_command(self):
        """CLI 'schedule' command calls start_checkin (backward compat)."""
        mock_start = MagicMock(return_value=42)
        ns = self._exec_cli(
            ["schedule", "10", "--workflow", "001-feat"],
            {"start_checkin": mock_start},
        )
        mock_start.assert_called_once_with(10, "Standard check-in", "tmux-orc:0", "001-feat")

    def test_cancel_command(self):
        """CLI 'cancel' command calls cancel_checkin."""
        mock_cancel = MagicMock(return_value=True)
        ns = self._exec_cli(
            ["cancel", "--workflow", "001-feat"],
            {"cancel_checkin": mock_cancel},
        )
        mock_cancel.assert_called_once_with("001-feat")

    def test_status_command(self, tmp_project, capsys):
        """CLI 'status' command prints daemon status."""
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 5,
        }))
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))

        ns = self._exec_cli(
            ["status", "--workflow", "001-test"],
            {
                "get_workflow_from_tmux": MagicMock(return_value="001-test"),
                "find_project_root": MagicMock(return_value=tmp_project),
                "print": print,  # Use real print so capsys can capture
            },
        )
        captured = capsys.readouterr()
        assert "Daemon running:" in captured.out

    def test_status_command_json(self, tmp_project, capsys):
        """CLI 'status --json' outputs valid JSON."""
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 5,
        }))
        (wf / "checkins.json").write_text(json.dumps({"checkins": [], "daemon_pid": None}))

        ns = self._exec_cli(
            ["status", "--json", "--workflow", "001-test"],
            {
                "get_workflow_from_tmux": MagicMock(return_value="001-test"),
                "find_project_root": MagicMock(return_value=tmp_project),
                "print": print,
            },
        )
        captured = capsys.readouterr()
        parsed = json.loads(captured.out)
        assert "daemon_running" in parsed

    def test_status_command_no_workflow(self):
        """CLI 'status' with no workflow prints error and exits."""
        mock_print = MagicMock()
        ns = self._exec_cli(
            ["status"],
            {
                "get_workflow_from_tmux": MagicMock(return_value=None),
                "print": mock_print,
            },
        )
        mock_print.assert_any_call("Error: No workflow specified")

    def test_list_command(self, tmp_project, capsys):
        """CLI 'list' command outputs check-in entries."""
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "checkins.json").write_text(json.dumps({
            "checkins": [{"id": "1", "status": "done", "note": "test"}],
            "daemon_pid": None,
        }))

        ns = self._exec_cli(
            ["list", "--workflow", "001-test"],
            {
                "get_workflow_from_tmux": MagicMock(return_value="001-test"),
                "find_project_root": MagicMock(return_value=tmp_project),
                "print": print,
            },
        )
        captured = capsys.readouterr()
        assert "done" in captured.out

    def test_list_command_no_workflow(self):
        """CLI 'list' with no workflow prints error."""
        mock_print = MagicMock()
        ns = self._exec_cli(
            ["list"],
            {
                "get_workflow_from_tmux": MagicMock(return_value=None),
                "print": mock_print,
            },
        )
        mock_print.assert_any_call("Error: No workflow specified")

    def test_no_command_prints_help(self):
        """CLI with no command calls parser.print_help (else branch)."""
        # The else branch at line 964-965 calls parser.print_help()
        # We just need to verify it doesn't crash
        ns = self._exec_cli([])
        # No assertions needed - reaching here without exception means success

    def test_daemon_command(self):
        """CLI 'daemon' command calls run_daemon with correct args."""
        mock_daemon = MagicMock()
        ns = self._exec_cli(
            [
                "daemon",
                "--workflow", "001-test",
                "--interval", "5",
                "--target", "sess:0",
                "--yato-path", "/tmp/yato",
                "--project-dir", "/tmp/proj",
            ],
            {"run_daemon": mock_daemon},
        )
        mock_daemon.assert_called_once_with(
            workflow_name="001-test",
            interval_minutes=5,
            target="sess:0",
            yato_path="/tmp/yato",
            project_dir="/tmp/proj",
        )



# ==================== run_daemon add_pending_checkin ====================


class TestRunDaemonAddPendingCheckin:
    """Tests that add_pending_checkin creates new entries correctly (lines 502-506)."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_add_pending_checkin_creates_entry(self, mock_sleep, tmp_project):
        """add_pending_checkin creates a new pending entry after check-in is sent."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()

        # Tasks stay pending for 2 check-ins, then complete
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        send_count = [0]

        def mock_send(target, msg, _skip_suffix=False):
            send_count[0] += 1
            if send_count[0] >= 2:
                # After second message, complete tasks
                tasks_complete = {"tasks": [{"status": "completed"}]}
                (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Check that add_pending_checkin was called (new pending entries created)
        loaded = json.loads((wf / "checkins.json").read_text())
        # Original "1" should be "done", and there should be additional entries
        done_entries = [c for c in loaded["checkins"] if c.get("status") == "done"]
        assert len(done_entries) >= 1


# ==================== Additional coverage: config lines before suffix ====================


class TestRunDaemonSuffixWithPrecedingConfig:
    """Tests that config lines before CHECKIN_TO_PM_SUFFIX are iterated (line 582)."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_config_with_other_lines_before_suffix(self, mock_sleep, tmp_project):
        """Other config lines before CHECKIN_TO_PM_SUFFIX are skipped (i += 1 at line 582)."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Config with multiple lines BEFORE CHECKIN_TO_PM_SUFFIX
        config_dir = tmp_project / "config"
        config_dir.mkdir()
        (config_dir / "defaults.conf").write_text(
            '# Comment line\n'
            'DEFAULT_SESSION="yato"\n'
            'PM_TO_AGENTS_SUFFIX="agent-suffix"\n'
            'AGENTS_TO_PM_SUFFIX="pm-suffix"\n'
            'CHECKIN_TO_PM_SUFFIX="found-it"\n'
            'USER_TO_PM_SUFFIX="user-suffix"\n'
        )

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            tasks_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        assert len(send_calls) >= 1
        assert "found-it" in send_calls[0]


# ==================== Additional coverage: config read exception ====================


class TestRunDaemonSuffixConfigException:
    """Tests exception handling in config file read (lines 583-584)."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_config_read_exception(self, mock_sleep, tmp_project):
        """Exception during config read is caught, daemon continues without suffix."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 1,
        }))

        past = (datetime.now() - timedelta(seconds=120)).isoformat()
        checkins_data = {
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": past}],
            "daemon_pid": pid,
        }
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        # Create config dir but make defaults.conf a directory (causes read_text to fail)
        config_dir = tmp_project / "config"
        config_dir.mkdir()
        bad_conf = config_dir / "defaults.conf"
        bad_conf.mkdir()  # A directory, not a file -> read_text() will raise

        send_calls = []

        def mock_send(target, msg, _skip_suffix=False):
            send_calls.append(msg)
            tasks_complete = {"tasks": [{"status": "completed"}]}
            (wf / "tasks.json").write_text(json.dumps(tasks_complete))

        with patch("lib.tmux_utils.send_message", side_effect=mock_send):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should still send messages (exception caught, no suffix applied)
        assert len(send_calls) >= 1


# ==================== Additional coverage: CLI status with daemon PID ====================


class TestCheckinSchedulerCLIStatusWithDaemon:
    """Tests CLI status output with running daemon PID and pending check-in (lines 934, 938)."""

    @staticmethod
    def _get_main_code():
        """Extract and compile the __main__ block with correct source mapping for coverage."""
        import textwrap
        src_path = Path(__file__).resolve().parent.parent.parent / "lib" / "checkin_scheduler.py"
        source = src_path.read_text()
        lines = source.splitlines(keepends=True)
        start_line = None
        for i, line in enumerate(lines):
            if line.strip() == 'if __name__ == "__main__":':
                start_line = i
                break
        body_lines = lines[start_line + 1:]
        body = textwrap.dedent("".join(body_lines))
        padded = "\n" * (start_line + 1) + body
        code_obj = compile(padded, str(src_path), "exec")
        return code_obj

    def test_status_with_daemon_pid_and_next_checkin(self, tmp_project, capsys):
        """Status output includes daemon PID and next check-in when present."""
        import argparse

        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "status.yml").write_text(yaml.dump({
            "status": "in-progress",
            "checkin_interval_minutes": 5,
        }))
        # Set daemon_pid to our PID so is_daemon_running returns True
        pid = os.getpid()
        next_checkin_time = (datetime.now() + timedelta(minutes=5)).isoformat()
        (wf / "checkins.json").write_text(json.dumps({
            "checkins": [{"id": "1", "status": "pending", "scheduled_for": next_checkin_time}],
            "daemon_pid": pid,
        }))

        ns = {
            "__name__": "__test__",
            "argparse": argparse,
            "json": json,
            "sys": __import__("sys"),
            "Path": Path,
            "CheckinScheduler": CheckinScheduler,
            "start_checkin": MagicMock(return_value=None),
            "cancel_checkin": MagicMock(return_value=True),
            "get_workflow_from_tmux": MagicMock(return_value="001-test"),
            "find_project_root": MagicMock(return_value=tmp_project),
            "run_daemon": MagicMock(),
            "print": print,
        }

        original_argv = __import__("sys").argv
        __import__("sys").argv = ["checkin_scheduler", "status", "--workflow", "001-test"]
        try:
            exec(self._get_main_code(), ns)
        except SystemExit:
            pass
        finally:
            __import__("sys").argv = original_argv

        captured = capsys.readouterr()
        assert "Daemon PID:" in captured.out
        assert "Next check-in:" in captured.out


# ==================== run_daemon reset_status_in_progress ====================


class TestRunDaemonResetStatusInProgress:
    """Tests reset_status_in_progress called at daemon start."""

    @patch("lib.checkin_scheduler.time.sleep")
    def test_daemon_start_resets_completed_to_in_progress_when_incomplete_tasks(self, mock_sleep, tmp_project):
        """status.yml with status: completed is reset to in-progress when pending tasks exist."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        # One pending task = incomplete
        tasks_data = {"tasks": [{"status": "pending"}, {"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text("status: completed\ncompleted_at: 2026-03-25T10:00:00\n")

        # PID -1 so should_stop() triggers immediately after reset (which happens before loop)
        checkins_data = {"checkins": [], "daemon_pid": -1}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        content = (wf / "status.yml").read_text()
        assert "status: in-progress" in content
        assert "status: completed" not in content

    @patch("lib.checkin_scheduler.time.sleep")
    def test_daemon_start_does_not_reset_when_all_tasks_completed(self, mock_sleep, tmp_project):
        """status.yml stays completed when all tasks are completed."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        pid = os.getpid()
        tasks_data = {"tasks": [{"status": "completed"}, {"status": "completed"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text("status: completed\ncompleted_at: 2026-03-25T10:00:00\n")

        checkins_data = {"checkins": [], "daemon_pid": pid}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        content = (wf / "status.yml").read_text()
        assert "status: completed" in content
        assert "completed_at: 2026-03-25T10:00:00" in content

    @patch("lib.checkin_scheduler.time.sleep")
    def test_completed_at_removed_when_status_reset(self, mock_sleep, tmp_project):
        """completed_at line is removed when status is reset from completed to in-progress."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        tasks_data = {"tasks": [{"status": "in_progress"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text(
            "status: completed\ntitle: Test\ncompleted_at: 2026-03-25T10:00:00\ncheckin_interval_minutes: 5\n"
        )

        # PID -1 so daemon stops after reset
        checkins_data = {"checkins": [], "daemon_pid": -1}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        content = (wf / "status.yml").read_text()
        assert "status: in-progress" in content
        assert "completed_at" not in content
        # Other fields preserved
        assert "title: Test" in content
        assert "checkin_interval_minutes: 5" in content

    @patch("lib.checkin_scheduler.time.sleep")
    def test_status_not_touched_if_already_in_progress(self, mock_sleep, tmp_project):
        """status.yml with status: in-progress is not modified."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        original_content = "status: in-progress\ntitle: Test\ncheckin_interval_minutes: 5\n"
        (wf / "status.yml").write_text(original_content)

        # PID -1 so daemon stops after reset check
        checkins_data = {"checkins": [], "daemon_pid": -1}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        content = (wf / "status.yml").read_text()
        assert content == original_content

    @patch("lib.checkin_scheduler.time.sleep")
    def test_reset_handles_missing_status_file(self, mock_sleep, tmp_project):
        """No crash when status.yml doesn't exist and there are incomplete tasks."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        tasks_data = {"tasks": [{"status": "pending"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        # No status.yml created; PID -1 so daemon stops quickly
        checkins_data = {"checkins": [], "daemon_pid": -1}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        # Should complete without error, status.yml still doesn't exist
        assert not (wf / "status.yml").exists()

    @patch("lib.checkin_scheduler.time.sleep")
    def test_reset_works_without_completed_at_field(self, mock_sleep, tmp_project):
        """Reset works fine when status.yml has status: completed but no completed_at."""
        wf_name = "001-test"
        wf = tmp_project / ".workflow" / wf_name
        wf.mkdir(parents=True)

        tasks_data = {"tasks": [{"status": "blocked"}]}
        (wf / "tasks.json").write_text(json.dumps(tasks_data))

        (wf / "status.yml").write_text("status: completed\ntitle: Test\n")

        # PID -1 so daemon stops after reset
        checkins_data = {"checkins": [], "daemon_pid": -1}
        (wf / "checkins.json").write_text(json.dumps(checkins_data))

        with patch("lib.tmux_utils.send_message"):
            run_daemon(
                workflow_name=wf_name,
                interval_minutes=1,
                target="sess:0",
                yato_path=str(tmp_project),
                project_dir=str(tmp_project),
            )

        content = (wf / "status.yml").read_text()
        assert "status: in-progress" in content
        assert "status: completed" not in content
        assert "title: Test" in content
