#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyyaml>=6.0",
# ]
# ///
"""
Workflow Operations - Utility functions for workflow management.

This module replaces workflow-utils.sh and provides functions for:
- Creating workflow folders
- Managing workflow state
- Generating workflow slugs
- Managing agents.yml and team.yml
"""

import glob as globmod
import os
import re
import subprocess
import sys
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

# Ensure yato venv site-packages are available when running from outside the project
_script_dir = Path(__file__).resolve().parent
_project_root = _script_dir.parent
_venv_site = globmod.glob(str(_project_root / ".venv" / "lib" / "python*" / "site-packages"))
if _venv_site and _venv_site[0] not in sys.path:
    sys.path.insert(0, _venv_site[0])

import yaml


class WorkflowOps:
    """Workflow operations utility class."""

    @staticmethod
    def get_next_workflow_number(project_path: str) -> str:
        """
        Get the next workflow number (001, 002, etc.).

        Args:
            project_path: Path to the project root

        Returns:
            Next workflow number as a zero-padded string (e.g., "001")
        """
        workflow_dir = Path(project_path) / ".workflow"

        if not workflow_dir.exists():
            return "001"

        max_num = 0
        for item in workflow_dir.iterdir():
            if item.is_dir() and re.match(r"^\d{3}-", item.name):
                try:
                    num = int(item.name[:3])
                    if num > max_num:
                        max_num = num
                except ValueError:
                    pass

        return f"{max_num + 1:03d}"

    @staticmethod
    def generate_workflow_slug(title: str, max_words: int = 4, max_length: int = 30) -> str:
        """
        Generate a URL-safe slug from a title.

        Args:
            title: The title/prompt to convert
            max_words: Maximum number of words to include
            max_length: Maximum slug length

        Returns:
            Slug like "add-user-authentication"
        """
        # Convert to lowercase, keep only alphanumeric and spaces
        slug = re.sub(r"[^a-z0-9 ]", "", title.lower())

        # Split into words
        words = slug.split()

        # Build result, skipping very short words (except the first)
        result_words = []
        for i, word in enumerate(words):
            # Skip very short words (a, an, the, etc.) unless it's the first word
            if len(word) <= 2 and i > 0:
                continue
            result_words.append(word)
            if len(result_words) >= max_words:
                break

        # Join with hyphens and truncate
        result = "-".join(result_words)
        return result[:max_length]

    @staticmethod
    def create_workflow_folder(
        project_path: str,
        title: str,
        initial_request: str = "",
        session: str = "",
        checkin_interval: int = 15,
    ) -> str:
        """
        Create a new workflow folder with initial structure.

        Args:
            project_path: Path to the project root
            title: Title/description for the workflow
            initial_request: The original user request
            session: Tmux session name
            checkin_interval: Check-in interval in minutes

        Returns:
            Folder name (e.g., "001-add-user-auth")
        """
        workflow_dir = Path(project_path) / ".workflow"
        workflow_dir.mkdir(parents=True, exist_ok=True)

        num = WorkflowOps.get_next_workflow_number(project_path)
        slug = WorkflowOps.generate_workflow_slug(title)
        folder_name = f"{num}-{slug}"
        full_path = workflow_dir / folder_name

        # Create the folder structure
        (full_path / "agents" / "pm").mkdir(parents=True, exist_ok=True)

        # Create status.yml
        status_data = {
            "status": "in-progress",
            "title": title,
            "initial_request": initial_request,
            "folder": folder_name,
            "checkin_interval_minutes": checkin_interval,
            "created_at": datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ"),
            "session": session,
            "agent_message_suffix": "",
            "checkin_message_suffix": "",
            "agent_to_pm_message_suffix": "",
            "user_to_pm_message_suffix": "",
        }

        status_file = full_path / "status.yml"
        with open(status_file, "w") as f:
            f.write("# Workflow Status\n")
            yaml.dump(status_data, f, default_flow_style=False, allow_unicode=True)

        return folder_name

    @staticmethod
    def get_current_workflow(project_path: str) -> Optional[str]:
        """
        Get the current workflow folder name.

        Tries in order:
        1. WORKFLOW_NAME environment variable (direct)
        2. tmux WORKFLOW_NAME env var (if in tmux)
        3. Most recent workflow folder (fallback for scripts/tests)

        Args:
            project_path: Path to the project root

        Returns:
            Workflow folder name or None
        """
        # Check direct environment variable first
        env_workflow = os.environ.get("WORKFLOW_NAME")
        if env_workflow:
            return env_workflow

        # Get from tmux environment variable (requires being in tmux)
        if os.environ.get("TMUX"):
            try:
                socket = os.environ.get("TMUX_SOCKET")
                tmux_cmd = ["tmux", "-L", socket] if socket else ["tmux"]
                result = subprocess.run(
                    tmux_cmd + ["showenv", "WORKFLOW_NAME"],
                    capture_output=True,
                    text=True,
                    check=True,
                )
                output = result.stdout.strip()
                if "=" in output:
                    workflow = output.split("=", 1)[1]
                    if workflow:
                        return workflow
            except subprocess.CalledProcessError:
                pass

        # Fallback: discover most recent workflow folder
        workflow_dir = Path(project_path) / ".workflow"
        if workflow_dir.exists():
            workflows = sorted(workflow_dir.glob("[0-9][0-9][0-9]-*"), reverse=True)
            if workflows and workflows[0].is_dir():
                return workflows[0].name

        return None

    @staticmethod
    def get_current_workflow_path(project_path: str) -> Optional[Path]:
        """
        Get the full path to the current workflow.

        Args:
            project_path: Path to the project root

        Returns:
            Path to workflow folder or None
        """
        current = WorkflowOps.get_current_workflow(project_path)
        if current:
            return Path(project_path) / ".workflow" / current
        return None

    @staticmethod
    def update_checkin_interval(project_path: str, interval: int) -> bool:
        """
        Update the check-in interval in status.yml.

        Args:
            project_path: Path to the project root
            interval: New interval in minutes

        Returns:
            True if successful, False otherwise
        """
        workflow_path = WorkflowOps.get_current_workflow_path(project_path)
        if not workflow_path:
            print("Error: No current workflow")
            return False

        status_file = workflow_path / "status.yml"
        if not status_file.exists():
            return False

        content = status_file.read_text()
        content = re.sub(
            r"^checkin_interval_minutes: \d+",
            f"checkin_interval_minutes: {interval}",
            content,
            flags=re.MULTILINE,
        )
        status_file.write_text(content)
        return True

    @staticmethod
    def list_workflows(project_path: str) -> List[Dict[str, str]]:
        """
        List all workflows in a project.

        Args:
            project_path: Path to the project root

        Returns:
            List of workflow dictionaries with name, status, and title
        """
        workflow_dir = Path(project_path) / ".workflow"
        if not workflow_dir.exists():
            return []

        workflows = []
        for item in sorted(workflow_dir.iterdir()):
            if item.is_dir() and re.match(r"^\d{3}-", item.name):
                status_file = item / "status.yml"
                wf = {"name": item.name, "status": "unknown", "title": ""}

                if status_file.exists():
                    try:
                        with open(status_file, "r") as f:
                            data = yaml.safe_load(f)
                            wf["status"] = data.get("status", "unknown")
                            wf["title"] = data.get("title", "")
                    except yaml.YAMLError:
                        pass

                workflows.append(wf)

        return workflows

    @staticmethod
    def create_agents_yml(
        project_path: str,
        session: str,
        workflow_path: Optional[str] = None,
    ) -> Optional[str]:
        """
        Create agents.yml file with PM entry.

        Args:
            project_path: Path to the project root
            session: Tmux session name
            workflow_path: Path to workflow (auto-detected if not provided)

        Returns:
            Path to created file or None
        """
        if workflow_path is None:
            wf_path = WorkflowOps.get_current_workflow_path(project_path)
            if not wf_path:
                print("Error: No current workflow")
                return None
            workflow_path = str(wf_path)

        agents_file = Path(workflow_path) / "agents.yml"

        data = {
            "pm": {
                "name": "pm",
                "role": "pm",
                "session": session,
                "window": 0,
                "pane": 1,
                "model": "opus",
            },
            "agents": [],
        }

        WorkflowOps._write_agents_yml(agents_file, data)

        print(f"Created agents.yml: {agents_file}")
        return str(agents_file)

    @staticmethod
    def add_agent_to_yml(
        project_path: str,
        agent_name: str,
        agent_role: str,
        window_number: int,
        model: str,
        session: str,
    ) -> bool:
        """
        Add an agent to agents.yml.

        Args:
            project_path: Path to the project root
            agent_name: Agent name
            agent_role: Agent role (developer, qa, etc.)
            window_number: Tmux window number
            model: Model to use (haiku, sonnet, opus)
            session: Tmux session name

        Returns:
            True if successful, False otherwise
        """
        workflow_path = WorkflowOps.get_current_workflow_path(project_path)
        if not workflow_path:
            print("Error: No current workflow")
            return False

        agents_file = workflow_path / "agents.yml"
        if not agents_file.exists():
            # Auto-create agents.yml
            WorkflowOps.create_agents_yml(project_path, session, str(workflow_path))

        with open(agents_file, "r") as f:
            data = yaml.safe_load(f)

        if data is None:
            data = {"agents": []}

        if "agents" not in data:
            data["agents"] = []

        # Add the new agent
        data["agents"].append({
            "name": agent_name,
            "role": agent_role,
            "session": session,
            "window": window_number,
            "model": model,
        })

        WorkflowOps._write_agents_yml(agents_file, data)

        print(f"Added {agent_name} to agents.yml (window {window_number})")
        return True

    @staticmethod
    def _write_agents_yml(agents_file: Path, data: dict) -> None:
        """Write agents.yml with consistent key ordering (name first)."""
        with open(agents_file, "w") as f:
            f.write("# Agent Registry\n")
            f.write("# This file tracks all agents and their tmux locations\n\n")

            # Write PM section if present
            if "pm" in data:
                pm = data["pm"]
                f.write("pm:\n")
                for key in ["name", "role", "session", "window", "pane", "model"]:
                    if key in pm:
                        val = pm[key]
                        if isinstance(val, str):
                            f.write(f"  {key}: \"{val}\"\n")
                        else:
                            f.write(f"  {key}: {val}\n")
                f.write("\n")

            # Write agents section
            agents = data.get("agents", [])
            if not agents:
                f.write("agents: []\n")
            else:
                f.write("agents:\n")
                for agent in agents:
                    first = True
                    for key in ["name", "role", "session", "window", "model"]:
                        if key in agent:
                            val = agent[key]
                            prefix = "  - " if first else "    "
                            if isinstance(val, str):
                                f.write(f"{prefix}{key}: {val}\n")
                            else:
                                f.write(f"{prefix}{key}: {val}\n")
                            first = False

    @staticmethod
    def save_team_structure(
        project_path: str,
        agents: List[Dict[str, str]],
        yato_path: Optional[str] = None,
    ) -> Optional[str]:
        """
        Save team structure to team.yml and create agent files.

        Args:
            project_path: Path to the project root
            agents: List of agent dicts with name, role, model keys
            yato_path: Path to yato installation (for init-agent-files.sh)

        Returns:
            Path to team.yml or None
        """
        workflow_path = WorkflowOps.get_current_workflow_path(project_path)
        if not workflow_path:
            print("Error: No current workflow")
            return None

        team_file = workflow_path / "team.yml"

        # Create team.yml
        team_data = {"agents": agents}

        with open(team_file, "w") as f:
            f.write("# Team Structure\n")
            f.write("# This file defines the agents that will be created for this workflow.\n")
            f.write("# Used by /parse-prd-to-tasks to assign tasks to appropriate agents.\n")
            f.write(f"# Created: {datetime.utcnow().strftime('%Y-%m-%dT%H:%M:%SZ')}\n\n")
            yaml.dump(team_data, f, default_flow_style=False, allow_unicode=True)

        # Create agent files for each agent
        if yato_path is None:
            yato_path = os.environ.get("YATO_PATH", str(Path(__file__).resolve().parent.parent))

        init_script = Path(yato_path) / "bin" / "init-agent-files.sh"
        if init_script.exists():
            for agent in agents:
                subprocess.run([
                    "bash", str(init_script),
                    project_path,
                    agent.get("name", ""),
                    agent.get("role", ""),
                    agent.get("model", "sonnet"),
                ], check=False)

        print(f"Saved team structure to: {team_file}")
        return str(team_file)

    @staticmethod
    def update_status_yml(project_path: str, updates: Dict[str, Any]) -> bool:
        """
        Update fields in status.yml.

        Args:
            project_path: Path to the project root
            updates: Dictionary of fields to update

        Returns:
            True if successful, False otherwise
        """
        workflow_path = WorkflowOps.get_current_workflow_path(project_path)
        if not workflow_path:
            print("Error: No current workflow")
            return False

        status_file = workflow_path / "status.yml"
        if not status_file.exists():
            print("Error: status.yml not found")
            return False

        # Load existing data
        with open(status_file, "r") as f:
            data = yaml.safe_load(f)

        if data is None:
            data = {}

        # Update with new values
        data.update(updates)

        # Write back
        with open(status_file, "w") as f:
            f.write("# Workflow Status\n")
            yaml.dump(data, f, default_flow_style=False, allow_unicode=True)

        return True


# ==================== Module-level functions ====================

def get_next_workflow_number(project_path: str) -> str:
    """Get the next workflow number."""
    return WorkflowOps.get_next_workflow_number(project_path)


def generate_workflow_slug(title: str) -> str:
    """Generate a URL-safe slug from a title."""
    return WorkflowOps.generate_workflow_slug(title)


def create_workflow_folder(project_path: str, title: str, **kwargs) -> str:
    """Create a new workflow folder."""
    return WorkflowOps.create_workflow_folder(project_path, title, **kwargs)


def get_current_workflow(project_path: str) -> Optional[str]:
    """Get the current workflow name."""
    return WorkflowOps.get_current_workflow(project_path)


def get_current_workflow_path(project_path: str) -> Optional[Path]:
    """Get the current workflow path."""
    return WorkflowOps.get_current_workflow_path(project_path)


def list_workflows(project_path: str) -> List[Dict[str, str]]:
    """List all workflows."""
    return WorkflowOps.list_workflows(project_path)


if __name__ == "__main__":
    import argparse
    import json

    parser = argparse.ArgumentParser(description="Workflow operations for Yato")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # list command
    list_parser = subparsers.add_parser("list", help="List workflows")
    list_parser.add_argument("--project", "-p", default=".", help="Project path")

    # current command
    current_parser = subparsers.add_parser("current", help="Get current workflow")
    current_parser.add_argument("--project", "-p", default=".", help="Project path")

    # create command
    create_parser = subparsers.add_parser("create", help="Create workflow folder")
    create_parser.add_argument("title", help="Workflow title")
    create_parser.add_argument("--project", "-p", default=".", help="Project path")
    create_parser.add_argument("--session", "-s", default="", help="Tmux session name")

    # slug command
    slug_parser = subparsers.add_parser("slug", help="Generate slug from title")
    slug_parser.add_argument("title", help="Title to convert")

    # next-number command
    next_parser = subparsers.add_parser("next-number", help="Get next workflow number")
    next_parser.add_argument("--project", "-p", default=".", help="Project path")

    args = parser.parse_args()

    if args.command == "list":
        workflows = list_workflows(args.project)
        for wf in workflows:
            print(f"{wf['name']} [{wf['status']}]")
            if wf.get("title"):
                print(f"  {wf['title']}")

    elif args.command == "current":
        current = get_current_workflow(args.project)
        if current:
            print(current)
        else:
            print("(no current workflow)")

    elif args.command == "create":
        folder = create_workflow_folder(args.project, args.title, session=args.session)
        print(f"Created: {folder}")

    elif args.command == "slug":
        print(generate_workflow_slug(args.title))

    elif args.command == "next-number":
        print(get_next_workflow_number(args.project))

    else:
        parser.print_help()
