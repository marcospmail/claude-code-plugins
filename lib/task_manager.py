#!/usr/bin/env python3
"""
Task Manager - Manage tasks for workflows.

This module replaces the bash scripts:
- assign-task.sh
- tasks-display.sh
- tasks-table.sh

Tasks are stored in .workflow/<workflow-name>/tasks.json
Agent-specific tasks are appended to .workflow/<workflow>/agents/<agent>/agent-tasks.md
"""

import json
import os
import subprocess
import time
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any


class TaskManager:
    """
    Manages tasks for a workflow.

    Tasks are stored in tasks.json with the following format:
    {
        "tasks": [
            {
                "id": "T1",
                "subject": "Task description",
                "description": "Detailed description",
                "agent": "developer",
                "status": "pending",
                "blockedBy": [],
                "blocks": []
            }
        ]
    }
    """

    def __init__(self, workflow_path: str):
        """
        Initialize the task manager.

        Args:
            workflow_path: Path to the workflow directory (e.g., .workflow/001-feature)
        """
        self.workflow_path = Path(workflow_path)
        self.tasks_file = self.workflow_path / "tasks.json"
        self.agents_dir = self.workflow_path / "agents"

    def _load_tasks(self) -> Dict[str, Any]:
        """Load tasks from tasks.json."""
        if not self.tasks_file.exists():
            return {"tasks": []}
        try:
            with open(self.tasks_file, "r") as f:
                return json.load(f)
        except (json.JSONDecodeError, IOError):
            return {"tasks": []}

    def _save_tasks(self, data: Dict[str, Any]) -> None:
        """Save tasks to tasks.json."""
        self.tasks_file.parent.mkdir(parents=True, exist_ok=True)
        with open(self.tasks_file, "w") as f:
            json.dump(data, f, indent=2)

    def get_tasks(self, status: Optional[str] = None, agent: Optional[str] = None) -> List[Dict[str, Any]]:
        """
        Get tasks, optionally filtered by status or agent.

        Args:
            status: Filter by status (pending, in_progress, blocked, completed)
            agent: Filter by assigned agent

        Returns:
            List of task dictionaries.
        """
        data = self._load_tasks()
        tasks = data.get("tasks", [])

        if status:
            tasks = [t for t in tasks if t.get("status") == status]
        if agent:
            tasks = [t for t in tasks if t.get("agent") == agent]

        return tasks

    def get_task(self, task_id: str) -> Optional[Dict[str, Any]]:
        """Get a specific task by ID."""
        data = self._load_tasks()
        for task in data.get("tasks", []):
            if task.get("id") == task_id:
                return task
        return None

    def update_task_status(self, task_id: str, status: str) -> bool:
        """
        Update a task's status.

        Args:
            task_id: Task ID
            status: New status (pending, in_progress, blocked, completed)

        Returns:
            True if updated, False if task not found.
        """
        data = self._load_tasks()
        for task in data.get("tasks", []):
            if task.get("id") == task_id:
                task["status"] = status
                if status == "completed":
                    task["completed_at"] = datetime.now().isoformat()
                self._save_tasks(data)
                return True
        return False

    def assign_task(self, agent_name: str, task_description: str) -> bool:
        """
        Assign a task to an agent by appending to their agent-tasks.md file.

        This creates a checklist in the agent's progress file with:
        - Task items (converted from "- item" to "[ ] item")
        - A "Notify PM when done" item at the end

        Args:
            agent_name: Name of the agent (e.g., "developer", "qa")
            task_description: Task description, can include "- item" lines

        Returns:
            True if successful.
        """
        # Validate agent exists in team.yml (warning only)
        team_file = self.workflow_path / "team.yml"
        if team_file.exists():
            try:
                content = team_file.read_text()
                if f"name: {agent_name}" not in content:
                    print(f"WARNING: Agent '{agent_name}' not found in team.yml")
                    print("Continuing anyway (agent may be created later)...")
            except IOError:
                pass

        # Setup paths
        agent_dir = self.agents_dir / agent_name
        progress_file = agent_dir / "agent-tasks.md"

        agent_dir.mkdir(parents=True, exist_ok=True)

        # Create file with strict format if it doesn't exist
        if not progress_file.exists():
            progress_file.write_text("## Tasks\n\n## References\n")

        # Convert "- item" to "[ ] item"
        checklist_lines = []
        for line in task_description.split("\n"):
            if line.startswith("- "):
                checklist_lines.append(f"[ ] {line[2:]}")
            else:
                checklist_lines.append(line)
        checklist = "\n".join(checklist_lines)

        # Read current content
        content = progress_file.read_text()

        # Insert tasks BEFORE the ## References section
        if "## References" in content:
            parts = content.split("## References")
            new_content = (
                parts[0] +
                checklist + "\n" +
                '[ ] **Notify PM when done** (use: notify-pm.sh DONE "Completed: <summary>")\n\n' +
                "## References" +
                parts[1]
            )
        else:
            # No References section, append at end
            new_content = (
                content +
                "\n" + checklist + "\n" +
                '[ ] **Notify PM when done** (use: notify-pm.sh DONE "Completed: <summary>")\n'
            )

        progress_file.write_text(new_content)

        print(f"Task assigned to {agent_name}")
        print(f"Progress file: {progress_file}")
        return True

    def get_incomplete_count(self) -> int:
        """Get count of incomplete tasks (pending, in_progress, blocked)."""
        tasks = self.get_tasks()
        return len([t for t in tasks if t.get("status") in ("pending", "in_progress", "blocked")])

    def display_tasks(self, max_tasks: int = 20) -> str:
        """
        Display tasks in a simple list format.

        Args:
            max_tasks: Maximum number of tasks to display

        Returns:
            Formatted string for display.
        """
        tasks = self.get_tasks()

        if not tasks:
            return "(no tasks yet)"

        # Status icons
        icons = {
            "pending": "○",
            "in_progress": "◐",
            "blocked": "✗",
            "completed": "●"
        }

        lines = []
        for task in tasks[:max_tasks]:
            status = task.get("status", "pending")
            icon = icons.get(status, "?")
            task_id = task.get("id", "?")
            subject = task.get("subject", "No subject")[:45]
            agent = task.get("agent", "?")
            lines.append(f"{icon} {task_id}: {subject} [{agent}]")

        if len(tasks) > max_tasks:
            lines.append(f"... and {len(tasks) - max_tasks} more tasks")

        return "\n".join(lines)

    def display_tasks_table(self) -> str:
        """
        Display tasks in a table format.

        Returns:
            Markdown table string.
        """
        tasks = self.get_tasks()

        if not tasks:
            return "(no tasks)"

        lines = [
            "| ID | Task | Agent | Status |",
            "|----|------|-------|--------|"
        ]

        for task in tasks:
            task_id = task.get("id", "?")
            subject = task.get("subject", "No subject")[:40]
            agent = task.get("agent", "?")
            status = task.get("status", "pending")
            blocked_by = task.get("blockedBy", [])

            # Format status column
            if status == "blocked" or (status == "pending" and blocked_by):
                if blocked_by:
                    status_display = f"blocked by {', '.join(blocked_by)}"
                else:
                    status_display = "blocked"
            else:
                status_display = status

            lines.append(f"| {task_id} | {subject} | {agent} | {status_display} |")

        return "\n".join(lines)

    def run_display_loop(self, interval: int = 3) -> None:
        """
        Run a continuous display loop (for use in tmux panes).

        Args:
            interval: Refresh interval in seconds
        """
        # Clear screen once at start
        print("\033[2J\033[H", end="")

        while True:
            # Move cursor to top-left without clearing (prevents flicker)
            print("\033[H", end="")

            print("TASKS                              ")
            print("───────────────────────────────────")

            if self.tasks_file.exists():
                print(self.display_tasks())
            else:
                print("(waiting for tasks.json...)")

            print("")
            print("───────────────────────────────────")
            # Clear to end of screen
            print("\033[J", end="")

            time.sleep(interval)


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


def find_tasks_file(project_path: Optional[str] = None) -> Optional[Path]:
    """
    Find the tasks.json file for the current workflow.

    Args:
        project_path: Project path (defaults to cwd)

    Returns:
        Path to tasks.json or None if not found.
    """
    if project_path is None:
        project_root = find_project_root()
        if project_root is None:
            return None
        project_path = str(project_root)

    project = Path(project_path)

    # Try to get workflow from tmux
    workflow_name = get_workflow_from_tmux()
    if workflow_name and workflow_name != "-WORKFLOW_NAME":
        tasks_file = project / ".workflow" / workflow_name / "tasks.json"
        if tasks_file.exists():
            return tasks_file

    # Fallback: try current symlink
    current_link = project / ".workflow" / "current"
    if current_link.is_symlink():
        workflow_name = current_link.resolve().name
        tasks_file = project / ".workflow" / workflow_name / "tasks.json"
        if tasks_file.exists():
            return tasks_file

    # Last fallback: find first numbered workflow
    workflow_dir = project / ".workflow"
    if workflow_dir.exists():
        for item in sorted(workflow_dir.iterdir()):
            if item.is_dir() and item.name[:3].isdigit():
                tasks_file = item / "tasks.json"
                if tasks_file.exists():
                    return tasks_file

    return None


def assign_task(
    agent_name: str,
    task_description: str,
    project_path: Optional[str] = None,
    workflow_name: Optional[str] = None,
) -> bool:
    """
    Assign a task to an agent.

    Args:
        agent_name: Agent name (e.g., "developer")
        task_description: Task description
        project_path: Project path (defaults to cwd)
        workflow_name: Workflow name (auto-detected if not provided)

    Returns:
        True if successful.
    """
    if project_path is None:
        project_root = find_project_root()
        if project_root is None:
            print("Error: Could not find .workflow/ directory.")
            return False
        project_path = str(project_root)

    if workflow_name is None:
        workflow_name = get_workflow_from_tmux()

    if not workflow_name:
        # Try current symlink
        current_link = Path(project_path) / ".workflow" / "current"
        if current_link.is_symlink():
            workflow_name = current_link.resolve().name

    if not workflow_name:
        print("Error: Could not determine workflow name.")
        return False

    workflow_path = Path(project_path) / ".workflow" / workflow_name
    if not workflow_path.exists():
        print(f"Error: Workflow directory not found: {workflow_path}")
        return False

    manager = TaskManager(str(workflow_path))
    return manager.assign_task(agent_name, task_description)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Task manager for Yato")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # assign command
    assign_parser = subparsers.add_parser("assign", help="Assign task to agent")
    assign_parser.add_argument("agent", help="Agent name")
    assign_parser.add_argument("task", help="Task description")
    assign_parser.add_argument("--project", "-p", help="Project path")
    assign_parser.add_argument("--workflow", "-w", help="Workflow name")

    # list command
    list_parser = subparsers.add_parser("list", help="List tasks")
    list_parser.add_argument("--status", "-s", help="Filter by status")
    list_parser.add_argument("--agent", "-a", help="Filter by agent")
    list_parser.add_argument("--project", "-p", help="Project path")

    # table command
    table_parser = subparsers.add_parser("table", help="Display tasks as table")
    table_parser.add_argument("--project", "-p", help="Project path")

    # display command (continuous loop)
    display_parser = subparsers.add_parser("display", help="Run continuous display loop")
    display_parser.add_argument("--project", "-p", help="Project path")
    display_parser.add_argument("--interval", "-i", type=int, default=3, help="Refresh interval")

    args = parser.parse_args()

    if args.command == "assign":
        assign_task(args.agent, args.task, args.project, args.workflow)

    elif args.command == "list":
        tasks_file = find_tasks_file(args.project)
        if tasks_file:
            manager = TaskManager(str(tasks_file.parent))
            tasks = manager.get_tasks(args.status, args.agent)
            for task in tasks:
                print(json.dumps(task, indent=2))
        else:
            print("(no tasks file found)")

    elif args.command == "table":
        tasks_file = find_tasks_file(args.project)
        if tasks_file:
            manager = TaskManager(str(tasks_file.parent))
            print(manager.display_tasks_table())
        else:
            print("(no tasks file found)")

    elif args.command == "display":
        tasks_file = find_tasks_file(args.project)
        if tasks_file:
            manager = TaskManager(str(tasks_file.parent))
            try:
                manager.run_display_loop(args.interval)
            except KeyboardInterrupt:
                print("\nDisplay stopped.")
        else:
            print("(no tasks file found)")

    else:
        parser.print_help()
