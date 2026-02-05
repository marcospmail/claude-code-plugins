#!/usr/bin/env python3
"""
Check-in Scheduler - Schedule and manage periodic check-ins for workflows.

This module manages check-ins using a SINGLE LONG-RUNNING DAEMON process instead of
a chain of one-shot processes. This provides:
- Direct PID-based process control (kill to cancel)
- No chain-breaking issues (one process, either alive or dead)
- No temp files in /tmp
- Simpler state management

Check-ins are stored in .workflow/<workflow-name>/checkins.json
The daemon PID is stored in checkins.json under "daemon_pid"
"""

import json
import os
import signal
import subprocess
import sys
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any

import yaml


# How often the daemon checks for cancellation/completion (seconds)
DAEMON_POLL_INTERVAL = 10


class CheckinScheduler:
    """
    Manages check-in scheduling for workflows.

    Check-ins are stored per-workflow in .workflow/<workflow>/checkins.json
    """

    def __init__(self, workflow_path: Optional[str] = None):
        """
        Initialize the scheduler.

        Args:
            workflow_path: Path to the workflow directory (e.g., .workflow/001-feature)
                          If not provided, will attempt to auto-detect from tmux env.
        """
        self.workflow_path = Path(workflow_path) if workflow_path else None
        self._checkins_file: Optional[Path] = None

    @property
    def checkins_file(self) -> Path:
        """Get the path to the checkins.json file."""
        if self._checkins_file is None:
            if self.workflow_path is None:
                raise ValueError("Workflow path not set")
            self._checkins_file = self.workflow_path / "checkins.json"
        return self._checkins_file

    @property
    def status_file(self) -> Path:
        """Get the path to the status.yml file."""
        if self.workflow_path is None:
            raise ValueError("Workflow path not set")
        return self.workflow_path / "status.yml"

    @property
    def tasks_file(self) -> Path:
        """Get the path to the tasks.json file."""
        if self.workflow_path is None:
            raise ValueError("Workflow path not set")
        return self.workflow_path / "tasks.json"

    def _load_checkins(self) -> Dict[str, Any]:
        """Load check-ins from the JSON file."""
        if not self.checkins_file.exists():
            return {"checkins": [], "daemon_pid": None}
        try:
            with open(self.checkins_file, "r") as f:
                data = json.load(f)
                # Ensure daemon_pid key exists
                if "daemon_pid" not in data:
                    data["daemon_pid"] = None
                return data
        except (json.JSONDecodeError, IOError):
            return {"checkins": [], "daemon_pid": None}

    def _save_checkins(self, data: Dict[str, Any]) -> None:
        """Save check-ins to the JSON file."""
        self.checkins_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.checkins_file, "w") as f:
            json.dump(data, f, indent=2)

    def is_daemon_running(self) -> bool:
        """Check if the check-in daemon is currently running."""
        data = self._load_checkins()
        pid = data.get("daemon_pid")
        if pid is None:
            return False
        try:
            # Check if process exists (signal 0 doesn't kill, just checks)
            os.kill(pid, 0)
            return True
        except (OSError, ProcessLookupError):
            return False

    def get_daemon_pid(self) -> Optional[int]:
        """Get the daemon PID if it's running."""
        data = self._load_checkins()
        pid = data.get("daemon_pid")
        if pid is None:
            return None
        try:
            os.kill(pid, 0)
            return pid
        except (OSError, ProcessLookupError):
            return None

    def get_pending_count(self) -> int:
        """Get the number of pending check-ins."""
        data = self._load_checkins()
        return len([c for c in data.get("checkins", []) if c.get("status") == "pending"])

    def get_interval(self) -> Optional[int]:
        """Get the current check-in interval in minutes from status.yml."""
        if self.status_file.exists():
            try:
                with open(self.status_file, "r") as f:
                    data = yaml.safe_load(f)
                if data and isinstance(data, dict):
                    value = data.get("checkin_interval_minutes")
                    if value is not None and value != "_":
                        return int(value)
            except (ValueError, IOError, yaml.YAMLError):
                pass
        return None

    def get_incomplete_tasks_count(self) -> int:
        """Get the number of incomplete tasks."""
        if not self.tasks_file.exists():
            return 0
        try:
            with open(self.tasks_file, "r") as f:
                data = json.load(f)
            incomplete = [t for t in data.get("tasks", [])
                          if t.get("status") in ("pending", "in_progress", "blocked")]
            return len(incomplete)
        except (json.JSONDecodeError, IOError):
            return 0

    def start(
        self,
        interval_minutes: Optional[int] = None,
        note: str = "Standard check-in",
        target: str = "tmux-orc:0",
        yato_path: Optional[str] = None,
    ) -> Optional[int]:
        """
        Start the check-in daemon.

        Args:
            interval_minutes: Minutes between check-ins (reads from status.yml if not provided)
            note: Note describing the check-in purpose
            target: Target window/pane for the check-in message
            yato_path: Path to yato installation (for scripts)

        Returns:
            Daemon PID if started, None if already running or error
        """
        # Check if daemon is already running
        if self.is_daemon_running():
            print("Check-in daemon is already running.")
            print(f"PID: {self.get_daemon_pid()}")
            return None

        # Get interval from status.yml if not provided
        if interval_minutes is None:
            interval_minutes = self.get_interval()
            if interval_minutes is None:
                print("Error: No interval specified and none found in status.yml")
                return None

        # Determine yato path
        if yato_path is None:
            yato_path = os.environ.get("YATO_PATH", os.path.expanduser("~/dev/tools/yato"))

        # Get project directory (parent of .workflow)
        project_dir = str(self.workflow_path.parent.parent) if self.workflow_path else os.getcwd()
        workflow_name = self.workflow_path.name if self.workflow_path else ""

        # Load and update check-ins
        data = self._load_checkins()

        # Check if last entry was 'stopped' - if so, add 'resumed' entry
        if data["checkins"] and data["checkins"][-1].get("status") == "stopped":
            data["checkins"].append({
                "id": f"resume-{int(datetime.now().timestamp())}",
                "status": "resumed",
                "note": "Check-in loop resumed",
                "created_at": datetime.now().isoformat(),
            })

        # Calculate first check-in time
        next_checkin = datetime.now() + timedelta(minutes=interval_minutes)
        checkin_id = str(int(datetime.now().timestamp()))

        # Add pending check-in entry
        data["checkins"].append({
            "id": checkin_id,
            "status": "pending",
            "scheduled_for": next_checkin.isoformat(),
            "note": note,
            "target": target,
            "created_at": datetime.now().isoformat(),
        })

        self._save_checkins(data)

        print(f"Starting check-in daemon (interval: {interval_minutes}m)")

        # Start the daemon process
        daemon_pid = self._start_daemon(
            interval_minutes=interval_minutes,
            target=target,
            yato_path=yato_path,
            project_dir=project_dir,
            workflow_name=workflow_name,
        )

        if daemon_pid:
            # Store the PID
            data = self._load_checkins()
            data["daemon_pid"] = daemon_pid
            self._save_checkins(data)

            current_time = datetime.now().strftime("%H:%M:%S")
            run_time = next_checkin.strftime("%H:%M:%S")
            print(f"Daemon started with PID: {daemon_pid}")
            print(f"First check-in at: {run_time} (in {interval_minutes} minutes from {current_time})")

        return daemon_pid

    def _start_daemon(
        self,
        interval_minutes: int,
        target: str,
        yato_path: str,
        project_dir: str,
        workflow_name: str,
    ) -> Optional[int]:
        """
        Start the check-in daemon as a detached background process.

        Returns the daemon PID.
        """
        # Path to this module
        module_path = Path(__file__).resolve()

        # Build the daemon command
        cmd = [
            sys.executable,  # Use the same Python interpreter
            str(module_path),
            "daemon",
            "--workflow", workflow_name,
            "--interval", str(interval_minutes),
            "--target", target,
            "--yato-path", yato_path,
            "--project-dir", project_dir,
        ]

        # Start detached process
        process = subprocess.Popen(
            cmd,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            stdin=subprocess.DEVNULL,
            start_new_session=True,  # Detach from terminal
            cwd=project_dir,
        )

        return process.pid

    def cancel(self) -> bool:
        """
        Cancel the check-in daemon by killing it.

        Returns:
            True if daemon was killed, False if not running
        """
        pid = self.get_daemon_pid()

        if pid is None:
            print("No check-in daemon is running.")
            # Still mark as stopped in the file
            data = self._load_checkins()
            # Mark any pending as cancelled
            for c in data["checkins"]:
                if c.get("status") == "pending":
                    c["status"] = "cancelled"
                    c["cancelled_at"] = datetime.now().isoformat()
            # Add stopped entry
            data["checkins"].append({
                "id": f"stop-{int(datetime.now().timestamp())}",
                "status": "stopped",
                "note": "Check-in loop stopped",
                "created_at": datetime.now().isoformat(),
            })
            data["daemon_pid"] = None
            self._save_checkins(data)
            return False

        print(f"Killing check-in daemon (PID: {pid})...")

        try:
            os.kill(pid, signal.SIGTERM)
            # Wait a moment for graceful shutdown
            time.sleep(0.5)
            # Check if still alive, force kill if needed
            try:
                os.kill(pid, 0)
                os.kill(pid, signal.SIGKILL)
            except (OSError, ProcessLookupError):
                pass  # Already dead
        except (OSError, ProcessLookupError):
            pass  # Already dead

        # Update the file
        data = self._load_checkins()
        # Mark any pending as cancelled
        for c in data["checkins"]:
            if c.get("status") == "pending":
                c["status"] = "cancelled"
                c["cancelled_at"] = datetime.now().isoformat()
        # Add stopped entry
        data["checkins"].append({
            "id": f"stop-{int(datetime.now().timestamp())}",
            "status": "stopped",
            "note": "Check-in loop stopped",
            "created_at": datetime.now().isoformat(),
        })
        data["daemon_pid"] = None
        self._save_checkins(data)

        print("Check-in daemon stopped.")
        return True

    def list_checkins(self, status: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        List check-ins, optionally filtered by status.

        Args:
            status: Filter by status (pending, done, cancelled, stopped, resumed)

        Returns:
            List of check-in dictionaries.
        """
        data = self._load_checkins()
        checkins = data.get("checkins", [])

        if status:
            checkins = [c for c in checkins if c.get("status") == status]

        return checkins

    def status(self) -> Dict[str, Any]:
        """Get the current status of the check-in system."""
        data = self._load_checkins()
        daemon_running = self.is_daemon_running()
        pid = self.get_daemon_pid()
        interval = self.get_interval()
        incomplete_tasks = self.get_incomplete_tasks_count()

        # Find next pending check-in
        next_checkin = None
        for c in data.get("checkins", []):
            if c.get("status") == "pending":
                next_checkin = c.get("scheduled_for")
                break

        return {
            "daemon_running": daemon_running,
            "daemon_pid": pid,
            "interval_minutes": interval,
            "incomplete_tasks": incomplete_tasks,
            "next_checkin": next_checkin,
            "total_checkins": len(data.get("checkins", [])),
        }


# ==================== Daemon Entry Point ====================

def run_daemon(
    workflow_name: str,
    interval_minutes: int,
    target: str,
    yato_path: str,
    project_dir: str,
):
    """
    Run the check-in daemon loop.

    This function runs in a detached background process and:
    1. Sleeps in short intervals (DAEMON_POLL_INTERVAL)
    2. Checks for cancellation between sleeps
    3. Sends check-in messages when the interval elapses
    4. Stops automatically when all tasks are complete
    """
    os.chdir(project_dir)

    checkin_file = Path(f".workflow/{workflow_name}/checkins.json")
    status_file = Path(f".workflow/{workflow_name}/status.yml")
    tasks_file = Path(f".workflow/{workflow_name}/tasks.json")
    send_message_script = Path(yato_path) / "bin" / "send-message.sh"

    interval_seconds = interval_minutes * 60
    time_until_next_checkin = interval_seconds

    def load_checkins():
        if not checkin_file.exists():
            return {"checkins": [], "daemon_pid": None}
        try:
            with open(checkin_file, "r") as f:
                return json.load(f)
        except:
            return {"checkins": [], "daemon_pid": None}

    def save_checkins(data):
        checkin_file.parent.mkdir(parents=True, exist_ok=True)
        with open(checkin_file, "w") as f:
            json.dump(data, f, indent=2)

    def should_stop():
        """Check if we should stop the daemon."""
        data = load_checkins()
        # Check if our PID is still registered (cancel clears it)
        if data.get("daemon_pid") != os.getpid():
            return True
        # Check for explicit stop
        checkins = data.get("checkins", [])
        for c in reversed(checkins):
            if c.get("status") == "stopped":
                return True
            if c.get("status") in ("pending", "done", "resumed"):
                break
        return False

    def get_incomplete_tasks():
        """Get count of incomplete tasks."""
        if not tasks_file.exists():
            return 0
        try:
            with open(tasks_file, "r") as f:
                data = json.load(f)
            return len([t for t in data.get("tasks", [])
                        if t.get("status") in ("pending", "in_progress", "blocked")])
        except:
            return 0

    def mark_checkin_done(checkin_id: str):
        """Mark a check-in as done."""
        data = load_checkins()
        for c in data["checkins"]:
            if c.get("id") == checkin_id and c.get("status") == "pending":
                c["status"] = "done"
                c["completed_at"] = datetime.now().isoformat()
                break
        save_checkins(data)

    def add_pending_checkin() -> str:
        """Add a new pending check-in entry."""
        data = load_checkins()
        checkin_id = str(int(datetime.now().timestamp()))
        next_time = datetime.now() + timedelta(seconds=interval_seconds)
        data["checkins"].append({
            "id": checkin_id,
            "status": "pending",
            "scheduled_for": next_time.isoformat(),
            "note": f"Auto check-in ({get_incomplete_tasks()} tasks remaining)",
            "target": target,
            "created_at": datetime.now().isoformat(),
        })
        save_checkins(data)
        return checkin_id

    def stop_loop(reason: str):
        """Stop the daemon and mark as stopped."""
        data = load_checkins()
        # Mark pending as cancelled
        for c in data["checkins"]:
            if c.get("status") == "pending":
                c["status"] = "cancelled"
                c["cancelled_at"] = datetime.now().isoformat()
        # Add stopped entry
        data["checkins"].append({
            "id": f"stop-{int(datetime.now().timestamp())}",
            "status": "stopped",
            "note": reason,
            "created_at": datetime.now().isoformat(),
        })
        data["daemon_pid"] = None
        save_checkins(data)

    def update_status_completed():
        """Mark workflow status as completed."""
        if not status_file.exists():
            return
        try:
            with open(status_file, "r") as f:
                content = f.read()
            import re
            content = re.sub(r"^status:.*$", "status: completed", content, flags=re.MULTILINE)
            if "completed_at:" not in content:
                content = content.rstrip() + "\ncompleted_at: " + datetime.now().isoformat() + "\n"
            with open(status_file, "w") as f:
                f.write(content)
        except:
            pass

    def send_message(message: str):
        """Send a message to the target pane."""
        try:
            subprocess.run([str(send_message_script), target, message], check=False)
        except:
            pass

    # Get current pending check-in ID
    data = load_checkins()
    current_checkin_id = None
    for c in data.get("checkins", []):
        if c.get("status") == "pending":
            current_checkin_id = c.get("id")
            # Calculate actual time until this check-in
            try:
                scheduled = datetime.fromisoformat(c.get("scheduled_for", ""))
                time_until_next_checkin = max(0, (scheduled - datetime.now()).total_seconds())
            except:
                pass
            break

    # Main daemon loop
    while True:
        # Sleep for poll interval (or remaining time, whichever is smaller)
        sleep_time = min(DAEMON_POLL_INTERVAL, time_until_next_checkin)
        time.sleep(sleep_time)
        time_until_next_checkin -= sleep_time

        # Check if we should stop
        if should_stop():
            break

        # Check if it's time for a check-in
        if time_until_next_checkin <= 0:
            # Mark current check-in as done
            if current_checkin_id:
                mark_checkin_done(current_checkin_id)

            # Check incomplete tasks
            incomplete = get_incomplete_tasks()

            if incomplete > 0:
                # Send check-in message
                send_message(
                    f"Time for check-in! ({incomplete} tasks remaining). "
                    "REMINDER: If you received any [DONE] or [BLOCKED] notifications from agents, "
                    "update tasks.json immediately (change task status to 'completed' or 'blocked')."
                )

                # Schedule next check-in
                current_checkin_id = add_pending_checkin()
                time_until_next_checkin = interval_seconds
            else:
                # All tasks complete - stop the loop
                send_message(
                    "All tasks complete! Workflow marked as completed. Check-in loop stopped."
                )
                update_status_completed()
                stop_loop("All tasks complete")
                break


# ==================== Module-level functions ====================

def get_workflow_from_tmux() -> Optional[str]:
    """Get the workflow name from tmux environment variable."""
    try:
        result = subprocess.run(
            ["tmux", "showenv", "WORKFLOW_NAME"],
            capture_output=True,
            text=True,
            check=True,
        )
        # Output is "WORKFLOW_NAME=value" or "-WORKFLOW_NAME" if unset
        output = result.stdout.strip()
        if "=" in output:
            return output.split("=", 1)[1]
    except subprocess.CalledProcessError:
        pass
    return None


def find_project_root() -> Optional[Path]:
    """Find the project root by walking up looking for .workflow/"""
    current = Path.cwd()
    while current != current.parent:
        if (current / ".workflow").exists():
            return current
        current = current.parent
    return None


def cancel_checkin(workflow_name: Optional[str] = None) -> bool:
    """
    Cancel the check-in daemon for a workflow.

    Args:
        workflow_name: Workflow name. Auto-detected from tmux if not provided.

    Returns:
        True if daemon was killed, False if not running
    """
    if workflow_name is None:
        workflow_name = get_workflow_from_tmux()

    if not workflow_name:
        print("Error: No WORKFLOW_NAME set in tmux environment.")
        print("Run this from within a tmux session with an active workflow.")
        return False

    project_root = find_project_root()
    if project_root is None:
        print("Error: Could not find .workflow/ directory.")
        return False

    workflow_path = project_root / ".workflow" / workflow_name
    if not workflow_path.exists():
        print(f"Error: Workflow directory not found: {workflow_path}")
        return False

    scheduler = CheckinScheduler(str(workflow_path))
    return scheduler.cancel()


def start_checkin(
    minutes: Optional[int] = None,
    note: str = "Standard check-in",
    target: str = "tmux-orc:0",
    workflow_name: Optional[str] = None,
) -> Optional[int]:
    """
    Start the check-in daemon for a workflow.

    Args:
        minutes: Minutes between check-ins (reads from status.yml if not provided)
        note: Note for the check-in
        target: Target window for the message
        workflow_name: Workflow name. Auto-detected from tmux if not provided.

    Returns:
        Daemon PID if started, None otherwise.
    """
    if workflow_name is None:
        workflow_name = get_workflow_from_tmux()

    if not workflow_name:
        print("Error: No WORKFLOW_NAME set in tmux environment.")
        print("Run this from within a tmux session with an active workflow.")
        return None

    project_root = find_project_root()
    if project_root is None:
        print("Error: Could not find .workflow/ directory.")
        return None

    workflow_path = project_root / ".workflow" / workflow_name
    if not workflow_path.exists():
        print(f"Error: Workflow directory not found: {workflow_path}")
        return None

    scheduler = CheckinScheduler(str(workflow_path))
    return scheduler.start(minutes, note, target)


# Backward compatibility alias
def schedule_checkin(
    minutes: int,
    note: str = "Standard check-in",
    target: str = "tmux-orc:0",
    workflow_name: Optional[str] = None,
) -> Optional[int]:
    """Backward compatible alias for start_checkin."""
    return start_checkin(minutes, note, target, workflow_name)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Check-in scheduler for Yato")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # start command (replaces schedule)
    start_parser = subparsers.add_parser("start", help="Start the check-in daemon")
    start_parser.add_argument("minutes", type=int, nargs="?", help="Minutes between check-ins (optional, reads from status.yml)")
    start_parser.add_argument("--note", "-n", default="Standard check-in", help="Note for check-in")
    start_parser.add_argument("--target", "-t", default="tmux-orc:0", help="Target window")
    start_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    # schedule command (backward compatibility)
    schedule_parser = subparsers.add_parser("schedule", help="Start the check-in daemon (alias for start)")
    schedule_parser.add_argument("minutes", type=int, help="Minutes between check-ins")
    schedule_parser.add_argument("--note", "-n", default="Standard check-in", help="Note for check-in")
    schedule_parser.add_argument("--target", "-t", default="tmux-orc:0", help="Target window")
    schedule_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    # cancel command
    cancel_parser = subparsers.add_parser("cancel", help="Cancel the check-in daemon")
    cancel_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    # status command
    status_parser = subparsers.add_parser("status", help="Show check-in daemon status")
    status_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")
    status_parser.add_argument("--json", action="store_true", help="Output as JSON")

    # list command
    list_parser = subparsers.add_parser("list", help="List check-ins")
    list_parser.add_argument("--status", "-s", help="Filter by status")
    list_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    # daemon command (internal - called by start)
    daemon_parser = subparsers.add_parser("daemon", help="Run the daemon (internal)")
    daemon_parser.add_argument("--workflow", required=True, help="Workflow name")
    daemon_parser.add_argument("--interval", type=int, required=True, help="Interval in minutes")
    daemon_parser.add_argument("--target", required=True, help="Target pane")
    daemon_parser.add_argument("--yato-path", required=True, help="Yato path")
    daemon_parser.add_argument("--project-dir", required=True, help="Project directory")

    args = parser.parse_args()

    if args.command in ("start", "schedule"):
        minutes = getattr(args, "minutes", None)
        start_checkin(minutes, args.note, args.target, args.workflow)

    elif args.command == "cancel":
        cancel_checkin(args.workflow)

    elif args.command == "status":
        workflow_name = args.workflow or get_workflow_from_tmux()
        if not workflow_name:
            print("Error: No workflow specified")
            sys.exit(1)
        project_root = find_project_root()
        if project_root:
            workflow_path = project_root / ".workflow" / workflow_name
            if workflow_path.exists():
                scheduler = CheckinScheduler(str(workflow_path))
                status = scheduler.status()
                if args.json:
                    print(json.dumps(status, indent=2))
                else:
                    print(f"Daemon running: {status['daemon_running']}")
                    if status['daemon_pid']:
                        print(f"Daemon PID: {status['daemon_pid']}")
                    print(f"Interval: {status['interval_minutes']} minutes")
                    print(f"Incomplete tasks: {status['incomplete_tasks']}")
                    if status['next_checkin']:
                        print(f"Next check-in: {status['next_checkin']}")

    elif args.command == "list":
        workflow_name = args.workflow or get_workflow_from_tmux()
        if not workflow_name:
            print("Error: No workflow specified")
            sys.exit(1)
        project_root = find_project_root()
        if project_root:
            workflow_path = project_root / ".workflow" / workflow_name
            if workflow_path.exists():
                scheduler = CheckinScheduler(str(workflow_path))
                checkins = scheduler.list_checkins(args.status)
                for c in checkins:
                    print(json.dumps(c, indent=2))

    elif args.command == "daemon":
        # Run the daemon loop (called internally by start)
        run_daemon(
            workflow_name=args.workflow,
            interval_minutes=args.interval,
            target=args.target,
            yato_path=args.yato_path,
            project_dir=args.project_dir,
        )

    else:
        parser.print_help()
