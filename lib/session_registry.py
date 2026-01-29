#!/usr/bin/env python3
"""
Session Registry - Track active Claude agents in tmux sessions.

This module manages a JSON-based registry of all active agents,
their roles, windows, and relationships (e.g., which PM an agent reports to).
"""

import json
import os
from datetime import datetime
from pathlib import Path
from typing import Optional, List, Dict, Any

# Get the project root directory (parent of lib/)
PROJECT_ROOT = Path(__file__).parent.parent.absolute()
DEFAULT_REGISTRY_PATH = PROJECT_ROOT / ".yato" / "registry.json"


class Agent:
    """Represents a registered Claude agent."""

    def __init__(
        self,
        session_name: str,
        window_index: int,
        role: str,
        pm_window: Optional[str] = None,
        project_path: Optional[str] = None,
        status: str = "active",
        created_at: Optional[str] = None,
        agent_id: Optional[str] = None,
        # Dynamic agent fields
        name: Optional[str] = None,
        focus: Optional[str] = None,
        skills: Optional[List[str]] = None,
        briefing: Optional[str] = None,
        model: Optional[str] = None,  # haiku, sonnet, opus
        pane_index: Optional[int] = None  # For pane-based deployment
    ):
        self.session_name = session_name
        self.window_index = window_index
        self.pane_index = pane_index  # None for window-based, int for pane-based
        self.role = role
        self.pm_window = pm_window  # Format: "session:window" or "session:window.pane"
        self.project_path = project_path
        self.status = status  # active, paused, terminated
        self.created_at = created_at or datetime.now().isoformat()
        # Generate agent_id including pane if specified
        if agent_id:
            self.agent_id = agent_id
        elif pane_index is not None:
            self.agent_id = f"{session_name}:{window_index}.{pane_index}"
        else:
            self.agent_id = f"{session_name}:{window_index}"
        # Dynamic agent fields for custom personas
        self.name = name  # Display name for this agent
        self.focus = focus  # What this agent focuses on
        self.skills = skills or []  # Specific skills (e.g., ["react", "testing"])
        self.briefing = briefing  # Custom briefing text
        self.model = model  # Claude model: haiku, sonnet, opus

    @property
    def target(self) -> str:
        """Return the tmux target string for this agent."""
        if self.pane_index is not None:
            return f"{self.session_name}:{self.window_index}.{self.pane_index}"
        return f"{self.session_name}:{self.window_index}"

    def to_dict(self) -> Dict[str, Any]:
        """Convert agent to dictionary for JSON serialization."""
        data = {
            "agent_id": self.agent_id,
            "session_name": self.session_name,
            "window_index": self.window_index,
            "role": self.role,
            "pm_window": self.pm_window,
            "project_path": self.project_path,
            "status": self.status,
            "created_at": self.created_at
        }
        # Include pane_index if set
        if self.pane_index is not None:
            data["pane_index"] = self.pane_index
        # Include dynamic fields if set
        if self.name:
            data["name"] = self.name
        if self.focus:
            data["focus"] = self.focus
        if self.skills:
            data["skills"] = self.skills
        if self.briefing:
            data["briefing"] = self.briefing
        if self.model:
            data["model"] = self.model
        return data

    @classmethod
    def from_dict(cls, data: Dict[str, Any]) -> "Agent":
        """Create an Agent from a dictionary."""
        return cls(
            session_name=data["session_name"],
            window_index=data["window_index"],
            role=data["role"],
            pm_window=data.get("pm_window"),
            project_path=data.get("project_path"),
            status=data.get("status", "active"),
            created_at=data.get("created_at"),
            agent_id=data.get("agent_id"),
            # Dynamic fields
            name=data.get("name"),
            focus=data.get("focus"),
            skills=data.get("skills"),
            briefing=data.get("briefing"),
            model=data.get("model"),
            pane_index=data.get("pane_index")
        )

    def __repr__(self) -> str:
        return f"Agent({self.agent_id}, role={self.role}, status={self.status})"


class SessionRegistry:
    """
    Manages the registry of active Claude agents.

    The registry is stored as a JSON file and tracks:
    - Agent locations (session:window)
    - Agent roles (orchestrator, pm, developer, etc.)
    - PM relationships (which PM an agent reports to)
    - Agent status (active, paused, terminated)
    """

    def __init__(self, registry_path: Optional[Path] = None):
        self.registry_path = Path(registry_path) if registry_path else DEFAULT_REGISTRY_PATH
        self._ensure_registry_exists()

    def _ensure_registry_exists(self) -> None:
        """Create registry file and directory if they don't exist."""
        self.registry_path.parent.mkdir(parents=True, exist_ok=True)
        if not self.registry_path.exists():
            self._save_registry({"agents": [], "created_at": datetime.now().isoformat(), "last_updated": None})

    def _load_registry(self) -> Dict[str, Any]:
        """Load the registry from disk."""
        try:
            with open(self.registry_path, 'r') as f:
                return json.load(f)
        except (json.JSONDecodeError, FileNotFoundError):
            return {"agents": [], "created_at": datetime.now().isoformat(), "last_updated": None}

    def _save_registry(self, data: Dict[str, Any]) -> None:
        """Save the registry to disk."""
        data["last_updated"] = datetime.now().isoformat()
        with open(self.registry_path, 'w') as f:
            json.dump(data, f, indent=2)

    def register_agent(
        self,
        session_name: str,
        window_index: int,
        role: str,
        pm_window: Optional[str] = None,
        project_path: Optional[str] = None,
        name: Optional[str] = None,
        focus: Optional[str] = None,
        skills: Optional[List[str]] = None,
        briefing: Optional[str] = None,
        model: Optional[str] = None,
        pane_index: Optional[int] = None
    ) -> Agent:
        """
        Register a new agent in the registry.

        Args:
            session_name: The tmux session name
            window_index: The window index within the session
            role: Agent role (orchestrator, pm, developer, qa, etc.)
            pm_window: The PM's window this agent reports to (format: "session:window" or "session:window.pane")
            project_path: The project directory the agent is working on
            name: Display name for this agent
            focus: What this agent focuses on (dynamic persona)
            skills: List of skills this agent has
            briefing: Custom briefing text for this agent
            model: Claude model to use (haiku, sonnet, opus)
            pane_index: The pane index for pane-based deployment

        Returns:
            The registered Agent object
        """
        agent = Agent(
            session_name=session_name,
            window_index=window_index,
            role=role,
            pm_window=pm_window,
            project_path=project_path,
            name=name,
            focus=focus,
            skills=skills,
            briefing=briefing,
            model=model,
            pane_index=pane_index
        )

        registry = self._load_registry()

        # Check if agent already exists (by target)
        existing_idx = None
        for i, a in enumerate(registry["agents"]):
            if a.get("agent_id") == agent.agent_id:
                existing_idx = i
                break

        if existing_idx is not None:
            # Update existing agent
            registry["agents"][existing_idx] = agent.to_dict()
        else:
            # Add new agent
            registry["agents"].append(agent.to_dict())

        self._save_registry(registry)
        return agent

    def unregister_agent(self, agent_id: str) -> bool:
        """
        Remove an agent from the registry.

        Args:
            agent_id: The agent ID (format: "session:window")

        Returns:
            True if agent was found and removed, False otherwise
        """
        registry = self._load_registry()
        original_count = len(registry["agents"])
        registry["agents"] = [a for a in registry["agents"] if a.get("agent_id") != agent_id]

        if len(registry["agents"]) < original_count:
            self._save_registry(registry)
            return True
        return False

    def get_agent(self, agent_id: str) -> Optional[Agent]:
        """
        Get an agent by ID.

        Args:
            agent_id: The agent ID (format: "session:window")

        Returns:
            Agent object if found, None otherwise
        """
        registry = self._load_registry()
        for a in registry["agents"]:
            if a.get("agent_id") == agent_id:
                return Agent.from_dict(a)
        return None

    def get_agent_by_target(self, session: str, window: int) -> Optional[Agent]:
        """
        Get an agent by session and window.

        Args:
            session: The tmux session name
            window: The window index

        Returns:
            Agent object if found, None otherwise
        """
        return self.get_agent(f"{session}:{window}")

    def list_agents(
        self,
        role: Optional[str] = None,
        session: Optional[str] = None,
        status: Optional[str] = None
    ) -> List[Agent]:
        """
        List all registered agents, optionally filtered.

        Args:
            role: Filter by role (e.g., "developer", "pm")
            session: Filter by session name
            status: Filter by status (active, paused, terminated)

        Returns:
            List of Agent objects matching the filters
        """
        registry = self._load_registry()
        agents = []

        for a in registry["agents"]:
            if role and a.get("role") != role:
                continue
            if session and a.get("session_name") != session:
                continue
            if status and a.get("status") != status:
                continue
            agents.append(Agent.from_dict(a))

        return agents

    def get_pm_for_agent(self, agent_id: str) -> Optional[Agent]:
        """
        Get the Project Manager for a given agent.

        Args:
            agent_id: The agent ID (format: "session:window")

        Returns:
            The PM Agent if found, None otherwise
        """
        agent = self.get_agent(agent_id)
        if not agent or not agent.pm_window:
            return None

        return self.get_agent(agent.pm_window)

    def get_team_for_pm(self, pm_agent_id: str) -> List[Agent]:
        """
        Get all agents that report to a specific PM.

        Args:
            pm_agent_id: The PM's agent ID (format: "session:window")

        Returns:
            List of Agent objects that report to this PM
        """
        registry = self._load_registry()
        team = []

        for a in registry["agents"]:
            if a.get("pm_window") == pm_agent_id:
                team.append(Agent.from_dict(a))

        return team

    def update_agent_status(self, agent_id: str, status: str) -> bool:
        """
        Update an agent's status.

        Args:
            agent_id: The agent ID (format: "session:window")
            status: New status (active, paused, terminated)

        Returns:
            True if agent was found and updated, False otherwise
        """
        registry = self._load_registry()

        for a in registry["agents"]:
            if a.get("agent_id") == agent_id:
                a["status"] = status
                self._save_registry(registry)
                return True

        return False

    def clear_terminated(self) -> int:
        """
        Remove all terminated agents from the registry.

        Returns:
            Number of agents removed
        """
        registry = self._load_registry()
        original_count = len(registry["agents"])
        registry["agents"] = [a for a in registry["agents"] if a.get("status") != "terminated"]
        removed = original_count - len(registry["agents"])

        if removed > 0:
            self._save_registry(registry)

        return removed


# Convenience functions for CLI usage
def get_registry(registry_path: Optional[str] = None) -> SessionRegistry:
    """Get a SessionRegistry instance."""
    path = Path(registry_path) if registry_path else None
    return SessionRegistry(path)


if __name__ == "__main__":
    # Simple test
    registry = SessionRegistry()

    # Register a test agent
    agent = registry.register_agent(
        session_name="test-session",
        window_index=0,
        role="developer",
        pm_window="test-session:1",
        project_path="/tmp/test-project"
    )
    print(f"Registered: {agent}")

    # List all agents
    agents = registry.list_agents()
    print(f"All agents: {agents}")

    # Get the agent
    retrieved = registry.get_agent("test-session:0")
    print(f"Retrieved: {retrieved}")

    # Clean up test
    registry.unregister_agent("test-session:0")
    print("Test agent removed")
