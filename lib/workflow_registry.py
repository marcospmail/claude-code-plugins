#!/usr/bin/env python3
"""
Workflow Registry - Track agents per-workflow in .workflow/*/agents.yml

This module replaces the global SessionRegistry with workflow-scoped storage.
Agents are stored in the workflow's agents.yml file, not a global registry.
"""

import os
import subprocess
import sys
from pathlib import Path
from typing import Optional, List, Dict, Any

import yaml

# Handle imports for both `uv run` and direct script execution
try:
    from lib.session_registry import Agent
except ModuleNotFoundError:
    # Running as script, add parent directory to path
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from lib.session_registry import Agent


class WorkflowRegistry:
    """
    Manages agents for a specific workflow.

    Storage: .workflow/<workflow-name>/agents.yml

    Example agents.yml format:
    ```yaml
    pm:
      name: pm
      role: pm
      session: "myproject"
      window: 0
      pane: 1
      model: opus

    agents:
      - name: developer
        role: developer
        session: "myproject"
        window: 1
        model: sonnet
    ```
    """

    def __init__(self, workflow_path: Path):
        """
        Initialize registry for a specific workflow.

        Args:
            workflow_path: Full path to the workflow folder (e.g., /path/to/project/.workflow/001-feature)
        """
        self.workflow_path = Path(workflow_path)
        self.agents_file = self.workflow_path / "agents.yml"

    @classmethod
    def from_project(cls, project_path: Path, workflow_name: Optional[str] = None) -> Optional["WorkflowRegistry"]:
        """
        Create a WorkflowRegistry for a project, auto-detecting the workflow.

        Args:
            project_path: Path to the project root
            workflow_name: Explicit workflow name, or None to auto-detect

        Returns:
            WorkflowRegistry instance or None if no workflow found
        """
        project_path = Path(project_path).expanduser().resolve()
        workflow_dir = project_path / ".workflow"

        if not workflow_dir.exists():
            return None

        # If workflow_name provided, use it
        if workflow_name:
            workflow_path = workflow_dir / workflow_name
            if workflow_path.exists():
                return cls(workflow_path)
            return None

        # Try to get workflow name from WORKFLOW_NAME env var
        workflow_name = os.environ.get("WORKFLOW_NAME")
        if workflow_name:
            workflow_path = workflow_dir / workflow_name
            if workflow_path.exists():
                return cls(workflow_path)

        # Try to get from tmux environment
        workflow_name = cls._get_tmux_workflow_name()
        if workflow_name:
            workflow_path = workflow_dir / workflow_name
            if workflow_path.exists():
                return cls(workflow_path)

        # NOTE: We do NOT read .workflow/current file - it doesn't exist
        # Multiple workflows can run simultaneously, there is no single "current"

        # Fallback: Find most recent workflow folder (for discovery only)
        workflows = sorted(workflow_dir.glob("[0-9][0-9][0-9]-*"), reverse=True)
        if workflows:
            return cls(workflows[0])

        return None

    @staticmethod
    def _get_tmux_workflow_name() -> Optional[str]:
        """Get WORKFLOW_NAME from tmux environment."""
        try:
            result = subprocess.run(
                ["tmux", "showenv", "WORKFLOW_NAME"],
                capture_output=True,
                text=True
            )
            if result.returncode == 0:
                # Output is "WORKFLOW_NAME=value"
                line = result.stdout.strip()
                if "=" in line:
                    return line.split("=", 1)[1]
        except (subprocess.CalledProcessError, FileNotFoundError):
            pass
        return None

    def _load_agents_yml(self) -> Dict[str, Any]:
        """Load agents.yml file."""
        if not self.agents_file.exists():
            return {"pm": None, "agents": []}

        try:
            with open(self.agents_file) as f:
                data = yaml.safe_load(f)
                return data or {"pm": None, "agents": []}
        except (yaml.YAMLError, IOError):
            return {"pm": None, "agents": []}

    def _save_agents_yml(self, data: Dict[str, Any]) -> None:
        """Save agents.yml file."""
        self.workflow_path.mkdir(parents=True, exist_ok=True)
        with open(self.agents_file, "w") as f:
            yaml.dump(data, f, default_flow_style=False, sort_keys=False)

    def _agent_from_yml_entry(self, entry: Dict[str, Any], is_pm: bool = False) -> Agent:
        """Convert a YAML entry to an Agent object."""
        session = entry.get("session", "")
        window = entry.get("window", 0)
        pane = entry.get("pane")

        return Agent(
            session_name=session,
            window_index=window,
            role=entry.get("role", "developer"),
            pm_window=None if is_pm else f"{session}:0.1",  # PM is always at 0.1
            project_path=str(self.workflow_path.parent.parent),  # Back to project root
            status="active",
            name=entry.get("name"),
            model=entry.get("model"),
            pane_index=pane
        )

    def _agent_to_yml_entry(self, agent: Agent) -> Dict[str, Any]:
        """Convert an Agent to a YAML entry."""
        entry = {
            "name": agent.name or agent.role,
            "role": agent.role,
            "session": agent.session_name,
            "window": agent.window_index,
            "model": agent.model or "sonnet"
        }
        if agent.pane_index is not None:
            entry["pane"] = agent.pane_index
        return entry

    def get_pm(self) -> Optional[Agent]:
        """Get the PM agent for this workflow."""
        data = self._load_agents_yml()
        pm_data = data.get("pm")
        if pm_data and isinstance(pm_data, dict):
            return self._agent_from_yml_entry(pm_data, is_pm=True)
        return None

    def get_agent(self, name: str) -> Optional[Agent]:
        """
        Get an agent by name.

        Args:
            name: Agent name (e.g., "developer", "qa")
        """
        data = self._load_agents_yml()

        # Check PM first
        pm_data = data.get("pm")
        if pm_data and pm_data.get("name") == name:
            return self._agent_from_yml_entry(pm_data, is_pm=True)

        # Check other agents
        for entry in data.get("agents", []):
            if entry.get("name") == name:
                return self._agent_from_yml_entry(entry)

        return None

    def get_agent_by_target(self, session: str, window: int, pane: Optional[int] = None) -> Optional[Agent]:
        """
        Get an agent by tmux target.

        Args:
            session: Session name
            window: Window index
            pane: Optional pane index
        """
        data = self._load_agents_yml()

        # Check PM
        pm_data = data.get("pm")
        if pm_data:
            if (pm_data.get("session") == session and
                pm_data.get("window") == window and
                (pane is None or pm_data.get("pane") == pane)):
                return self._agent_from_yml_entry(pm_data, is_pm=True)

        # Check other agents
        for entry in data.get("agents", []):
            if (entry.get("session") == session and
                entry.get("window") == window and
                (pane is None or entry.get("pane") == pane)):
                return self._agent_from_yml_entry(entry)

        return None

    def list_agents(self, role: Optional[str] = None) -> List[Agent]:
        """
        List all agents in this workflow.

        Args:
            role: Optional filter by role
        """
        data = self._load_agents_yml()
        agents = []

        # Add PM
        pm_data = data.get("pm")
        if pm_data and isinstance(pm_data, dict):
            pm = self._agent_from_yml_entry(pm_data, is_pm=True)
            if role is None or pm.role == role:
                agents.append(pm)

        # Add other agents
        for entry in data.get("agents", []):
            agent = self._agent_from_yml_entry(entry)
            if role is None or agent.role == role:
                agents.append(agent)

        return agents

    def add_agent(self, agent: Agent, is_pm: bool = False) -> None:
        """
        Add or update an agent in the registry.

        Args:
            agent: Agent to add
            is_pm: Whether this is the PM agent
        """
        data = self._load_agents_yml()
        entry = self._agent_to_yml_entry(agent)

        if is_pm or agent.role == "pm":
            data["pm"] = entry
        else:
            # Check if agent already exists (by name)
            agents = data.get("agents", [])
            found = False
            for i, existing in enumerate(agents):
                if existing.get("name") == entry["name"]:
                    agents[i] = entry
                    found = True
                    break
            if not found:
                agents.append(entry)
            data["agents"] = agents

        self._save_agents_yml(data)

    def remove_agent(self, name: str) -> bool:
        """
        Remove an agent by name.

        Args:
            name: Agent name

        Returns:
            True if agent was found and removed
        """
        data = self._load_agents_yml()

        # Can't remove PM this way
        pm_data = data.get("pm")
        if pm_data and pm_data.get("name") == name:
            return False  # Can't remove PM

        # Remove from agents list
        agents = data.get("agents", [])
        original_len = len(agents)
        data["agents"] = [a for a in agents if a.get("name") != name]

        if len(data["agents"]) < original_len:
            self._save_agents_yml(data)
            return True
        return False

    def get_team(self) -> List[Agent]:
        """
        Get all non-PM agents (the team members).

        Returns:
            List of Agent objects excluding PM
        """
        data = self._load_agents_yml()
        agents = []

        for entry in data.get("agents", []):
            agents.append(self._agent_from_yml_entry(entry))

        return agents

    def get_session_name(self) -> Optional[str]:
        """Get the session name from PM entry."""
        pm = self.get_pm()
        return pm.session_name if pm else None


def get_workflow_registry(project_path: str, workflow_name: Optional[str] = None) -> Optional[WorkflowRegistry]:
    """Convenience function to get a WorkflowRegistry."""
    return WorkflowRegistry.from_project(Path(project_path), workflow_name)


if __name__ == "__main__":
    # Simple test
    import sys

    if len(sys.argv) > 1:
        project_path = sys.argv[1]
    else:
        project_path = "."

    registry = WorkflowRegistry.from_project(Path(project_path))

    if registry:
        print(f"Workflow path: {registry.workflow_path}")
        print(f"Agents file: {registry.agents_file}")

        pm = registry.get_pm()
        if pm:
            print(f"\nPM: {pm.name} at {pm.target}")

        team = registry.get_team()
        if team:
            print(f"\nTeam ({len(team)} agents):")
            for agent in team:
                print(f"  - {agent.name}: {agent.role} at {agent.target}")
    else:
        print(f"No workflow found for project: {project_path}")
