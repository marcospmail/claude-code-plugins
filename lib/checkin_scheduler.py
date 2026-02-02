#!/usr/bin/env python3
"""
Check-in Scheduler - Schedule and manage periodic check-ins for workflows.

This module replaces the bash scripts:
- schedule-checkin.sh
- cancel-checkin.sh
- checkin-display.sh (partially)

Check-ins are stored in .workflow/<workflow-name>/checkins.json
"""

import json
import os
import re
import subprocess
import time
from datetime import datetime, timedelta
from pathlib import Path
from typing import Optional, List, Dict, Any


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
        self._interval_file: Optional[Path] = None

    @property
    def checkins_file(self) -> Path:
        """Get the path to the checkins.json file."""
        if self._checkins_file is None:
            if self.workflow_path is None:
                raise ValueError("Workflow path not set")
            self._checkins_file = self.workflow_path / "checkins.json"
        return self._checkins_file

    @property
    def interval_file(self) -> Path:
        """Get the path to the checkin_interval.txt file."""
        if self._interval_file is None:
            if self.workflow_path is None:
                raise ValueError("Workflow path not set")
            self._interval_file = self.workflow_path / "checkin_interval.txt"
        return self._interval_file

    def _load_checkins(self) -> Dict[str, Any]:
        """Load check-ins from the JSON file."""
        if not self.checkins_file.exists():
            return {"checkins": []}
        try:
            with open(self.checkins_file, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return {"checkins": []}

    def _save_checkins(self, data: Dict[str, Any]) -> None:
        """Save check-ins to the JSON file."""
        self.checkins_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.checkins_file, "w") as f:
            json.dump(data, f, indent=2)

    def get_pending_count(self) -> int:
        """Get the number of pending check-ins."""
        data = self._load_checkins()
        return len([c for c in data.get("checkins", []) if c.get("status") == "pending"])

    def schedule(
        self,
        minutes: int,
        note: str = "Standard check-in",
        target: str = "tmux-orc:0",
        yato_path: Optional[str] = None,
    ) -> Optional[str]:
        """
        Schedule a check-in.

        Args:
            minutes: Minutes until the check-in
            note: Note describing the check-in purpose
            target: Target window/pane for the check-in message
            yato_path: Path to yato installation (for scripts)

        Returns:
            Check-in ID if scheduled, None if skipped (e.g., already pending)
        """
        # Guard: Check if there's already a pending check-in
        if self.get_pending_count() > 0:
            print(f"Note: Check-in already pending. Skipping duplicate schedule.")
            print("To force a new check-in, cancel the existing one first.")
            return None

        # Store the interval
        self.interval_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.interval_file, "w") as f:
            f.write(str(minutes))

        # Calculate scheduled time
        scheduled_for = datetime.now() + timedelta(minutes=minutes)
        checkin_id = str(int(datetime.now().timestamp()))

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

        # Add new pending check-in
        data["checkins"].append({
            "id": checkin_id,
            "status": "pending",
            "scheduled_for": scheduled_for.isoformat(),
            "note": note,
            "target": target,
            "created_at": datetime.now().isoformat(),
        })

        self._save_checkins(data)

        print(f"Scheduling check in {minutes} minutes with note: {note}")

        # Calculate times for display
        current_time = datetime.now().strftime("%H:%M:%S")
        run_time = scheduled_for.strftime("%H:%M:%S")

        # Get workflow name for the background process
        workflow_name = self.workflow_path.name if self.workflow_path else ""

        # Determine yato path
        if yato_path is None:
            yato_path = os.environ.get("YATO_PATH", os.path.expanduser("~/dev/tools/yato"))

        # Get project directory (parent of .workflow)
        project_dir = str(self.workflow_path.parent.parent) if self.workflow_path else os.getcwd()

        # Schedule the check-in using a background process
        self._schedule_background_checkin(
            checkin_id=checkin_id,
            minutes=minutes,
            target=target,
            note=note,
            yato_path=yato_path,
            project_dir=project_dir,
            workflow_name=workflow_name,
        )

        print(f"Scheduled successfully - process detached")
        print(f"SCHEDULED TO RUN AT: {run_time} (in {minutes} minutes from {current_time})")
        print(f"Check-in ID: {checkin_id}")

        return checkin_id

    def _schedule_background_checkin(
        self,
        checkin_id: str,
        minutes: int,
        target: str,
        note: str,
        yato_path: str,
        project_dir: str,
        workflow_name: str,
    ) -> None:
        """
        Schedule a check-in to run in the background after a delay.

        Uses subprocess.Popen with nohup-style detachment.
        """
        sleep_seconds = minutes * 60

        # Create the Python execution script
        exec_script = f'''
import json
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path

# Change to project directory
os.chdir("{project_dir}")

checkin_id = "{checkin_id}"
target = "{target}"
note = """{note}"""
yato_path = "{yato_path}"
workflow_name = "{workflow_name}"
checkin_file = f".workflow/{{workflow_name}}/checkins.json"

# Check if cancelled before executing
try:
    with open(checkin_file, "r") as f:
        data = json.load(f)
    for c in data["checkins"]:
        if c["id"] == checkin_id:
            if c.get("status") in ("cancelled", "done"):
                sys.exit(0)  # Already cancelled or done
            break
    else:
        sys.exit(0)  # Not found
except:
    sys.exit(0)

# Mark as done
try:
    with open(checkin_file, "r") as f:
        data = json.load(f)
    for c in data["checkins"]:
        if c["id"] == checkin_id:
            c["status"] = "done"
            c["completed_at"] = datetime.now().isoformat()
            break
    with open(checkin_file, "w") as f:
        json.dump(data, f, indent=2)
except:
    pass

# Send the check-in message
subprocess.run([
    "bash", f"{{yato_path}}/bin/send-message.sh",
    target, f"Time for check-in! Note: {{note}}"
])

# AUTO-CONTINUE: Check for incomplete tasks
status_file = f".workflow/{{workflow_name}}/status.yml"
tasks_file = f".workflow/{{workflow_name}}/tasks.json"

# Check if loop was stopped
try:
    with open(checkin_file, "r") as f:
        data = json.load(f)
    checkins = data.get("checkins", [])
    last_stop = None
    last_resume = None
    for c in checkins:
        if c.get("status") == "stopped":
            last_stop = c.get("created_at", "")
        elif c.get("status") == "resumed":
            last_resume = c.get("created_at", "")
    if last_stop and (not last_resume or last_stop > last_resume):
        sys.exit(0)  # Loop was stopped
except:
    pass

# Check for incomplete tasks
if Path(tasks_file).exists():
    try:
        with open(tasks_file, "r") as f:
            data = json.load(f)
        incomplete = [t for t in data.get("tasks", []) if t.get("status") in ("pending", "in_progress", "blocked")]

        if incomplete:
            # Get interval from status.yml
            interval = 5
            if Path(status_file).exists():
                with open(status_file, "r") as f:
                    for line in f:
                        if "checkin_interval_minutes" in line:
                            parts = line.split(":")
                            if len(parts) >= 2:
                                try:
                                    interval = int(parts[1].strip())
                                except:
                                    pass
                            break

            # Schedule next check-in
            subprocess.run([
                "bash", f"{{yato_path}}/bin/schedule-checkin.sh",
                str(interval), f"Auto check-in ({{len(incomplete)}} tasks remaining)", target
            ])
        else:
            # All tasks done - update status and stop loop
            if Path(status_file).exists():
                with open(status_file, "r") as f:
                    content = f.read()
                content = re.sub(r"^status:.*$", "status: completed", content, flags=re.MULTILINE)
                if "completed_at:" not in content:
                    content = content.rstrip() + "\\ncompleted_at: " + datetime.now().isoformat() + "\\n"
                with open(status_file, "w") as f:
                    f.write(content)

            # Cancel check-ins and notify
            subprocess.run(["bash", f"{{yato_path}}/bin/cancel-checkin.sh"])
            subprocess.run([
                "bash", f"{{yato_path}}/bin/send-message.sh",
                target, "All tasks complete! Workflow marked as completed. Check-in loop stopped."
            ])
    except Exception as e:
        pass
'''

        # Write the script to a temp file
        import tempfile
        with tempfile.NamedTemporaryFile(mode='w', suffix='.py', delete=False) as f:
            f.write(exec_script)
            exec_script_path = f.name

        # Use nohup-style detachment
        # First sleep, then run the Python script
        cmd = f'sleep {sleep_seconds} && python3 "{exec_script_path}"'

        # Detach the process completely
        subprocess.Popen(
            ["bash", "-c", f"nohup bash -c '{cmd}' > /dev/null 2>&1 &"],
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )

    def cancel(self, checkin_id: Optional[str] = None) -> int:
        """
        Cancel check-ins.

        Args:
            checkin_id: Specific check-in ID to cancel. If None, cancels all pending.

        Returns:
            Number of check-ins cancelled.
        """
        data = self._load_checkins()
        cancelled_count = 0

        for c in data["checkins"]:
            if c.get("status") == "pending":
                if checkin_id is None or c.get("id") == checkin_id:
                    c["status"] = "cancelled"
                    c["cancelled_at"] = datetime.now().isoformat()
                    cancelled_count += 1

        # Add a stopped entry
        data["checkins"].append({
            "id": f"stop-{int(datetime.now().timestamp())}",
            "status": "stopped",
            "note": "Check-in loop stopped - all work complete",
            "created_at": datetime.now().isoformat(),
        })

        self._save_checkins(data)

        # Clear the interval file
        if self.interval_file.exists():
            self.interval_file.unlink()

        print(f"Cancelled {cancelled_count} pending check-in(s).")
        print("Check-in loop stopped.")

        return cancelled_count

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

    def get_interval(self) -> Optional[int]:
        """Get the current check-in interval in minutes."""
        if self.interval_file.exists():
            try:
                return int(self.interval_file.read_text().strip())
            except ValueError:
                return None
        return None


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


def cancel_checkin(workflow_name: Optional[str] = None) -> int:
    """
    Cancel all pending check-ins for a workflow.

    Args:
        workflow_name: Workflow name. Auto-detected from tmux if not provided.

    Returns:
        Number of check-ins cancelled.
    """
    if workflow_name is None:
        workflow_name = get_workflow_from_tmux()

    if not workflow_name:
        print("Error: No WORKFLOW_NAME set in tmux environment.")
        print("Run this from within a tmux session with an active workflow.")
        return 0

    project_root = find_project_root()
    if project_root is None:
        print("Error: Could not find .workflow/ directory.")
        return 0

    workflow_path = project_root / ".workflow" / workflow_name
    if not workflow_path.exists():
        print(f"Error: Workflow directory not found: {workflow_path}")
        return 0

    scheduler = CheckinScheduler(str(workflow_path))
    return scheduler.cancel()


def schedule_checkin(
    minutes: int,
    note: str = "Standard check-in",
    target: str = "tmux-orc:0",
    workflow_name: Optional[str] = None,
) -> Optional[str]:
    """
    Schedule a check-in for a workflow.

    Args:
        minutes: Minutes until check-in
        note: Note for the check-in
        target: Target window for the message
        workflow_name: Workflow name. Auto-detected from tmux if not provided.

    Returns:
        Check-in ID if scheduled, None otherwise.
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
    return scheduler.schedule(minutes, note, target)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Check-in scheduler for Yato")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # schedule command
    schedule_parser = subparsers.add_parser("schedule", help="Schedule a check-in")
    schedule_parser.add_argument("minutes", type=int, help="Minutes until check-in")
    schedule_parser.add_argument("--note", "-n", default="Standard check-in", help="Note for check-in")
    schedule_parser.add_argument("--target", "-t", default="tmux-orc:0", help="Target window")
    schedule_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    # cancel command
    cancel_parser = subparsers.add_parser("cancel", help="Cancel pending check-ins")
    cancel_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    # list command
    list_parser = subparsers.add_parser("list", help="List check-ins")
    list_parser.add_argument("--status", "-s", help="Filter by status")
    list_parser.add_argument("--workflow", "-w", help="Workflow name (auto-detected if not provided)")

    args = parser.parse_args()

    if args.command == "schedule":
        schedule_checkin(args.minutes, args.note, args.target, args.workflow)
    elif args.command == "cancel":
        cancel_checkin(args.workflow)
    elif args.command == "list":
        workflow_name = args.workflow or get_workflow_from_tmux()
        if not workflow_name:
            print("Error: No workflow specified")
        else:
            project_root = find_project_root()
            if project_root:
                workflow_path = project_root / ".workflow" / workflow_name
                if workflow_path.exists():
                    scheduler = CheckinScheduler(str(workflow_path))
                    checkins = scheduler.list_checkins(args.status)
                    for c in checkins:
                        print(json.dumps(c, indent=2))
    else:
        parser.print_help()
