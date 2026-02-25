"""Tests for lib/task_manager.py — task CRUD, status transitions, assignment."""

import json
import os
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch

import pytest
import yaml

from lib.task_manager import (
    TaskManager,
    assign_task,
    find_tasks_file,
    find_project_root,
    get_workflow_from_tmux,
)


# ==================== TaskManager.__init__ ====================


class TestTaskManagerInit:
    def test_sets_paths(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        assert tm.workflow_path == tmp_workflow
        assert tm.tasks_file == tmp_workflow / "tasks.json"
        assert tm.agents_dir == tmp_workflow / "agents"


# ==================== TaskManager._load_tasks ====================


class TestLoadTasks:
    def test_loads_existing_tasks(self, tmp_workflow, sample_tasks_data):
        tasks_file = tmp_workflow / "tasks.json"
        with open(tasks_file, "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        data = tm._load_tasks()
        assert len(data["tasks"]) == 3

    def test_missing_file_returns_empty(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        data = tm._load_tasks()
        assert data == {"tasks": []}

    def test_malformed_json(self, tmp_workflow):
        (tmp_workflow / "tasks.json").write_text("not json{{{")
        tm = TaskManager(str(tmp_workflow))
        data = tm._load_tasks()
        assert data == {"tasks": []}


# ==================== TaskManager._save_tasks ====================


class TestSaveTasks:
    def test_saves_json(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        data = {"tasks": [{"id": "T1", "subject": "Test"}]}
        tm._save_tasks(data)
        assert tm.tasks_file.exists()
        with open(tm.tasks_file) as f:
            loaded = json.load(f)
        assert loaded["tasks"][0]["id"] == "T1"

    def test_creates_parent_dir(self, tmp_path):
        wf = tmp_path / "nonexistent" / "workflow"
        tm = TaskManager(str(wf))
        tm._save_tasks({"tasks": []})
        assert tm.tasks_file.exists()


# ==================== TaskManager.get_tasks ====================


class TestGetTasks:
    def test_all_tasks(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        tasks = tm.get_tasks()
        assert len(tasks) == 3

    def test_filter_by_status(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        pending = tm.get_tasks(status="pending")
        assert len(pending) == 2
        completed = tm.get_tasks(status="completed")
        assert len(completed) == 1

    def test_filter_by_agent(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        dev_tasks = tm.get_tasks(agent="developer")
        assert len(dev_tasks) == 2
        qa_tasks = tm.get_tasks(agent="qa")
        assert len(qa_tasks) == 1

    def test_filter_by_both(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        tasks = tm.get_tasks(status="pending", agent="developer")
        assert len(tasks) == 1
        assert tasks[0]["id"] == "T1"

    def test_no_tasks(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        assert tm.get_tasks() == []


# ==================== TaskManager.get_task ====================


class TestGetTask:
    def test_existing_task(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        task = tm.get_task("T2")
        assert task is not None
        assert task["subject"] == "Write auth tests"

    def test_nonexistent_task(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        assert tm.get_task("T999") is None

    def test_no_tasks_file(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        assert tm.get_task("T1") is None


# ==================== TaskManager.update_task_status ====================


class TestUpdateTaskStatus:
    def test_update_to_in_progress(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.update_task_status("T1", "in_progress")
        assert result is True
        task = tm.get_task("T1")
        assert task["status"] == "in_progress"

    def test_update_to_completed_adds_timestamp(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.update_task_status("T1", "completed")
        assert result is True
        task = tm.get_task("T1")
        assert task["status"] == "completed"
        assert "completed_at" in task

    def test_update_nonexistent_task(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.update_task_status("T999", "completed")
        assert result is False

    def test_update_to_blocked(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.update_task_status("T1", "blocked")
        assert result is True
        task = tm.get_task("T1")
        assert task["status"] == "blocked"


# ==================== TaskManager.assign_task ====================


class TestAssignTask:
    def test_creates_agent_tasks_file(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        result = tm.assign_task("developer", "- Implement feature X\n- Add tests")
        assert result is True

        tasks_file = tmp_workflow / "agents" / "developer" / "agent-tasks.md"
        assert tasks_file.exists()
        content = tasks_file.read_text()
        assert "[ ] Implement feature X" in content
        assert "[ ] Add tests" in content
        assert "Notify PM when done" in content

    def test_appends_to_existing_file(self, tmp_workflow):
        agent_dir = tmp_workflow / "agents" / "developer"
        agent_dir.mkdir(parents=True)
        tasks_file = agent_dir / "agent-tasks.md"
        tasks_file.write_text("## Tasks\n[ ] Existing task\n\n## References\n- Doc link\n")

        tm = TaskManager(str(tmp_workflow))
        tm.assign_task("developer", "- New task")

        content = tasks_file.read_text()
        assert "Existing task" in content
        assert "[ ] New task" in content
        assert "## References" in content
        assert "Doc link" in content

    def test_agent_not_in_agents_yml(self, tmp_workflow):
        """Should warn but still create tasks."""
        # Create agents.yml without the agent
        agents_file = tmp_workflow / "agents.yml"
        with open(agents_file, "w") as f:
            yaml.dump({"agents": [{"name": "qa"}]}, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.assign_task("unknown-agent", "- Do something")
        assert result is True
        assert (tmp_workflow / "agents" / "unknown-agent" / "agent-tasks.md").exists()

    def test_no_agents_yml(self, tmp_workflow):
        """Should work even without agents.yml."""
        tm = TaskManager(str(tmp_workflow))
        result = tm.assign_task("dev", "- Task")
        assert result is True

    def test_converts_dash_items(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        tm.assign_task("dev", "- Item 1\n- Item 2\nPlain text")
        content = (tmp_workflow / "agents" / "dev" / "agent-tasks.md").read_text()
        assert "[ ] Item 1" in content
        assert "[ ] Item 2" in content
        assert "Plain text" in content  # Not converted

    def test_no_references_section(self, tmp_workflow):
        """If no References section exists, append at end."""
        agent_dir = tmp_workflow / "agents" / "dev"
        agent_dir.mkdir(parents=True)
        tasks_file = agent_dir / "agent-tasks.md"
        tasks_file.write_text("## Tasks\n")

        tm = TaskManager(str(tmp_workflow))
        tm.assign_task("dev", "- Task A")
        content = tasks_file.read_text()
        assert "[ ] Task A" in content
        assert "Notify PM when done" in content


# ==================== TaskManager.get_incomplete_count ====================


class TestGetIncompleteCount:
    def test_counts_incomplete(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        count = tm.get_incomplete_count()
        assert count == 2  # T1 and T2 are pending, T3 is completed

    def test_no_tasks(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        assert tm.get_incomplete_count() == 0

    def test_all_completed(self, tmp_workflow):
        data = {"tasks": [
            {"id": "T1", "status": "completed"},
            {"id": "T2", "status": "completed"},
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        assert tm.get_incomplete_count() == 0

    def test_blocked_counts(self, tmp_workflow):
        data = {"tasks": [
            {"id": "T1", "status": "blocked"},
            {"id": "T2", "status": "in_progress"},
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        assert tm.get_incomplete_count() == 2


# ==================== TaskManager.display_tasks ====================


class TestDisplayTasks:
    def test_no_tasks(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks()
        assert result == "(no tasks yet)"

    def test_displays_tasks(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks()
        assert "T1" in result
        assert "T2" in result
        assert "T3" in result
        assert "developer" in result
        assert "qa" in result

    def test_status_icons(self, tmp_workflow):
        data = {"tasks": [
            {"id": "T1", "subject": "Pending task", "agent": "dev", "status": "pending"},
            {"id": "T2", "subject": "In progress", "agent": "dev", "status": "in_progress"},
            {"id": "T3", "subject": "Blocked task", "agent": "dev", "status": "blocked"},
            {"id": "T4", "subject": "Done task", "agent": "dev", "status": "completed"},
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks()
        assert "○" in result  # pending
        assert "◐" in result  # in_progress
        assert "✗" in result  # blocked
        assert "●" in result  # completed

    def test_max_tasks(self, tmp_workflow):
        data = {"tasks": [
            {"id": f"T{i}", "subject": f"Task {i}", "agent": "dev", "status": "pending"}
            for i in range(1, 6)
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks(max_tasks=3)
        assert "... and 2 more tasks" in result

    def test_long_subject_truncated(self, tmp_workflow):
        data = {"tasks": [
            {"id": "T1", "subject": "A" * 100, "agent": "dev", "status": "pending"},
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks()
        # Subject should be truncated to 45 chars
        assert "A" * 45 in result
        assert "A" * 46 not in result


# ==================== TaskManager.display_tasks_table ====================


class TestDisplayTasksTable:
    def test_no_tasks(self, tmp_workflow):
        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert result == "(no tasks)"

    def test_table_format(self, tmp_workflow, sample_tasks_data):
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert "| ID | Task | Agent | Status |" in result
        assert "|----|------|-------|--------|" in result
        assert "| T1 |" in result

    def test_blocked_by_display(self, tmp_workflow):
        data = {"tasks": [
            {
                "id": "T1",
                "subject": "Blocked task",
                "agent": "dev",
                "status": "blocked",
                "blockedBy": ["T0"],
            },
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert "blocked by T0" in result

    def test_pending_with_blocked_by(self, tmp_workflow):
        data = {"tasks": [
            {
                "id": "T2",
                "subject": "Waiting",
                "agent": "dev",
                "status": "pending",
                "blockedBy": ["T1"],
            },
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert "blocked by T1" in result

    def test_subject_truncated(self, tmp_workflow):
        data = {"tasks": [
            {"id": "T1", "subject": "X" * 100, "agent": "dev", "status": "pending", "blockedBy": []},
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert "X" * 40 in result
        assert "X" * 41 not in result


# ==================== TaskManager.run_display_loop ====================


class TestDisplayTasksTableEdgeCases:
    def test_blocked_without_blocked_by(self, tmp_workflow):
        """A task with status=blocked but empty blockedBy should show 'blocked'."""
        data = {"tasks": [
            {
                "id": "T1",
                "subject": "Blocked no deps",
                "agent": "dev",
                "status": "blocked",
                "blockedBy": [],
            },
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert "| blocked |" in result

    def test_task_missing_status_field(self, tmp_workflow):
        """Task without status field should show 'pending' as default."""
        data = {"tasks": [
            {"id": "T1", "subject": "No status", "agent": "dev"},
        ]}
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(data, f)

        tm = TaskManager(str(tmp_workflow))
        result = tm.display_tasks_table()
        assert "pending" in result


class TestAssignTaskIOError:
    def test_agents_file_io_error(self, tmp_workflow):
        """IOError when reading agents.yml should be silently caught."""
        agents_file = tmp_workflow / "agents.yml"
        # Create a directory with the same name to trigger IOError
        agents_file.mkdir(parents=True, exist_ok=True)

        tm = TaskManager(str(tmp_workflow))
        result = tm.assign_task("dev", "- Task X")
        assert result is True


class TestRunDisplayLoop:
    def test_keyboard_interrupt(self, tmp_workflow):
        """run_display_loop should exit on KeyboardInterrupt."""
        tm = TaskManager(str(tmp_workflow))
        with patch("time.sleep", side_effect=KeyboardInterrupt):
            with pytest.raises(KeyboardInterrupt):
                tm.run_display_loop()

    def test_displays_tasks_when_file_exists(self, tmp_workflow, sample_tasks_data):
        """run_display_loop should display tasks when tasks.json exists."""
        with open(tmp_workflow / "tasks.json", "w") as f:
            json.dump(sample_tasks_data, f)

        tm = TaskManager(str(tmp_workflow))
        call_count = [0]

        def mock_sleep(n):
            call_count[0] += 1
            if call_count[0] >= 1:
                raise KeyboardInterrupt

        with patch("time.sleep", side_effect=mock_sleep):
            with pytest.raises(KeyboardInterrupt):
                tm.run_display_loop()


# ==================== Module-level functions ====================


class TestGetWorkflowFromTmux:
    def test_success(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock(returncode=0, stdout="WORKFLOW_NAME=001-feature\n")
        with patch("subprocess.run", return_value=mock):
            result = get_workflow_from_tmux()
            assert result == "001-feature"

    def test_failure(self, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = get_workflow_from_tmux()
            assert result is None

    def test_with_socket(self, monkeypatch):
        monkeypatch.setenv("TMUX_SOCKET", "mysock")
        mock = MagicMock(returncode=0, stdout="WORKFLOW_NAME=001-test\n")
        with patch("subprocess.run", return_value=mock) as mock_run:
            result = get_workflow_from_tmux()
            assert result == "001-test"
            cmd = mock_run.call_args[0][0]
            assert "-L" in cmd
            assert "mysock" in cmd


class TestFindProjectRoot:
    def test_finds_root(self, tmp_project, monkeypatch):
        (tmp_project / ".workflow").mkdir()
        sub = tmp_project / "src" / "module"
        sub.mkdir(parents=True)
        monkeypatch.chdir(sub)
        result = find_project_root()
        assert result == tmp_project

    def test_no_root_found(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        result = find_project_root()
        assert result is None


class TestFindTasksFile:
    def test_from_tmux_workflow(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_project / ".workflow" / "001-feature"
        wf.mkdir(parents=True)
        tasks_file = wf / "tasks.json"
        tasks_file.write_text('{"tasks":[]}')

        mock = MagicMock(returncode=0, stdout="WORKFLOW_NAME=001-feature\n")
        with patch("subprocess.run", return_value=mock):
            result = find_tasks_file(str(tmp_project))
            assert result == tasks_file

    def test_from_current_symlink(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_project / ".workflow" / "001-feature"
        wf.mkdir(parents=True)
        (wf / "tasks.json").write_text('{"tasks":[]}')
        current_link = tmp_project / ".workflow" / "current"
        current_link.symlink_to(wf)

        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = find_tasks_file(str(tmp_project))
            assert result == wf / "tasks.json"

    def test_fallback_to_first_numbered(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_project / ".workflow" / "001-first"
        wf.mkdir(parents=True)
        (wf / "tasks.json").write_text('{"tasks":[]}')

        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = find_tasks_file(str(tmp_project))
            assert result == wf / "tasks.json"

    def test_no_tasks_file(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = find_tasks_file(str(tmp_project))
            assert result is None

    def test_no_project_path_with_root(self, tmp_project, monkeypatch):
        """Without project path, auto-detects from cwd."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        (wf / "tasks.json").write_text('{"tasks":[]}')
        monkeypatch.chdir(tmp_project)

        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = find_tasks_file()
            assert result == wf / "tasks.json"

    def test_no_project_path(self, tmp_path, monkeypatch):
        """Without project path, tries to find project root from cwd."""
        monkeypatch.chdir(tmp_path)
        result = find_tasks_file()
        assert result is None

    def test_ignores_workflow_name_dash(self, tmp_project, monkeypatch):
        """Workflow name '-WORKFLOW_NAME' should be ignored."""
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        mock = MagicMock(returncode=0, stdout="WORKFLOW_NAME=-WORKFLOW_NAME\n")
        with patch("subprocess.run", return_value=mock):
            result = find_tasks_file(str(tmp_project))
            assert result is None


class TestAssignTaskFunction:
    def test_success(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)

        mock = MagicMock(returncode=0, stdout="WORKFLOW_NAME=001-test\n")
        with patch("subprocess.run", return_value=mock):
            result = assign_task("dev", "- Do stuff", str(tmp_project))
            assert result is True

    def test_no_project_root(self, tmp_path, monkeypatch):
        monkeypatch.chdir(tmp_path)
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = assign_task("dev", "task")
            assert result is False

    def test_no_workflow_name(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        (tmp_project / ".workflow").mkdir()
        monkeypatch.chdir(tmp_project)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = assign_task("dev", "task")
            assert result is False

    def test_workflow_not_found(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        (tmp_project / ".workflow").mkdir()

        mock = MagicMock(returncode=0, stdout="WORKFLOW_NAME=nonexistent\n")
        with patch("subprocess.run", return_value=mock):
            result = assign_task("dev", "task", str(tmp_project))
            assert result is False

    def test_with_current_symlink(self, tmp_project, monkeypatch):
        monkeypatch.delenv("TMUX_SOCKET", raising=False)
        wf = tmp_project / ".workflow" / "001-test"
        wf.mkdir(parents=True)
        current_link = tmp_project / ".workflow" / "current"
        current_link.symlink_to(wf)

        monkeypatch.chdir(tmp_project)
        with patch("subprocess.run", side_effect=subprocess.CalledProcessError(1, "t")):
            result = assign_task("dev", "- task")
            assert result is True
