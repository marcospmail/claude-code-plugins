#!/usr/bin/env python3
"""
PostToolUse hook that detects changes to tasks.json and restarts check-ins if needed.

When tasks.json is modified:
1. Check if the check-in daemon is stopped (PID not running)
2. Check if there are incomplete tasks (pending, in_progress, blocked)
3. If both conditions are true, restart the check-in daemon

This handles the scenario where:
- Check-in stops (tasks complete or manually cancelled)
- New task is added to tasks.json
- Check-in should automatically restart to monitor progress
"""

import json
import os
import sys
from pathlib import Path
from typing import Optional, Tuple

import yaml


def find_workflow_from_path(file_path: str) -> Optional[Tuple[Path, str]]:
    """
    Find the workflow directory and name from a tasks.json file path.

    Expected path format: /path/to/project/.workflow/<workflow-name>/tasks.json

    Returns:
        Tuple of (workflow_path, workflow_name) or None if not found
    """
    path = Path(file_path)

    # Check if this is a tasks.json in a .workflow directory
    if path.name != "tasks.json":
        return None

    # Parent should be the workflow folder (e.g., 001-feature-name)
    workflow_dir = path.parent

    # Parent of that should be .workflow
    if workflow_dir.parent.name != ".workflow":
        return None

    return workflow_dir, workflow_dir.name


def is_daemon_running(workflow_path: Path) -> bool:
    """
    Check if the check-in daemon is currently running.

    Uses the daemon_pid stored in checkins.json and verifies the process exists.
    """
    checkins_file = workflow_path / "checkins.json"

    if not checkins_file.exists():
        return False

    try:
        with open(checkins_file, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        return False

    pid = data.get("daemon_pid")
    if pid is None:
        return False

    try:
        # Signal 0 checks if process exists without killing it
        os.kill(pid, 0)
        return True
    except (OSError, ProcessLookupError):
        return False


def has_incomplete_tasks(workflow_path: Path) -> Tuple[bool, int]:
    """
    Check if there are incomplete tasks in tasks.json.

    Returns:
        Tuple of (has_incomplete, count)
    """
    tasks_file = workflow_path / "tasks.json"

    if not tasks_file.exists():
        return False, 0

    try:
        with open(tasks_file, "r") as f:
            data = json.load(f)
    except (json.JSONDecodeError, IOError):
        return False, 0

    tasks = data.get("tasks", [])
    incomplete = [t for t in tasks if t.get("status") in ("pending", "in_progress", "blocked")]

    return len(incomplete) > 0, len(incomplete)


def get_checkin_interval(workflow_path: Path) -> Optional[int]:
    """Get the check-in interval from status.yml.

    Returns None if the interval hasn't been configured yet (still placeholder "_").
    This prevents the hook from starting the daemon before the user selects an interval.
    """
    status_file = workflow_path / "status.yml"

    if not status_file.exists():
        return None

    try:
        with open(status_file, "r") as f:
            data = yaml.safe_load(f)
        if data and isinstance(data, dict):
            value = data.get("checkin_interval_minutes")
            if value is not None and value != "_":
                return int(value)
    except (ValueError, IOError, yaml.YAMLError):
        pass

    return None


def get_session_target(workflow_path: Path) -> str:
    """Get the session target from status.yml."""
    status_file = workflow_path / "status.yml"

    if not status_file.exists():
        return "tmux-orc:0"

    try:
        with open(status_file, "r") as f:
            data = yaml.safe_load(f)
        if data and isinstance(data, dict):
            session = data.get("session", "")
            if session:
                return f"{session}:0.1"
    except (IOError, yaml.YAMLError):
        pass

    return "tmux-orc:0"


def restart_checkin(workflow_path: Path, workflow_name: str, task_count: int) -> bool:
    """Restart the check-in daemon using Python API directly.

    Returns False if the interval hasn't been configured yet.
    """
    interval = get_checkin_interval(workflow_path)
    if interval is None:
        return False
    target = get_session_target(workflow_path)

    # Get yato path and add lib to path
    yato_path = os.environ.get("YATO_PATH", str(Path(__file__).resolve().parent.parent.parent))

    # Import CheckinScheduler directly to avoid tmux env dependency
    import importlib.util
    spec = importlib.util.spec_from_file_location(
        "checkin_scheduler",
        os.path.join(yato_path, "lib", "checkin_scheduler.py")
    )
    checkin_module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(checkin_module)

    # Use the CheckinScheduler's start() method (new daemon-based approach)
    scheduler = checkin_module.CheckinScheduler(str(workflow_path))
    scheduler.start(
        interval_minutes=interval,
        note=f"Auto-restart: tasks.json modified ({task_count} incomplete tasks)",
        target=target,
        yato_path=yato_path,
    )
    return True


def main():
    try:
        # Read hook input from stdin
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        # No input or invalid JSON - allow tool to proceed
        return 0

    # Get the file path that was written/edited
    tool_input = hook_input.get("tool_input", {}) or hook_input.get("toolInput", {})
    file_path = tool_input.get("file_path", "") or tool_input.get("path", "")

    # Only process tasks.json files
    if "tasks.json" not in file_path:
        return 0

    # Find the workflow directory
    result = find_workflow_from_path(file_path)
    if not result:
        return 0

    workflow_path, workflow_name = result

    # Check if daemon is running using PID
    if is_daemon_running(workflow_path):
        # Daemon is already running, nothing to do
        return 0

    # Check if there are incomplete tasks
    has_incomplete, count = has_incomplete_tasks(workflow_path)
    if not has_incomplete:
        # No incomplete tasks, nothing to restart
        return 0

    # Restart the check-in daemon (skip if interval not configured yet)
    if not restart_checkin(workflow_path, workflow_name, count):
        return 0

    # Output a message to stderr (won't affect hook result)
    print(f"[tasks-change-hook] Started check-in daemon: {count} incomplete tasks detected", file=sys.stderr)

    return 0


if __name__ == "__main__":
    sys.exit(main())
