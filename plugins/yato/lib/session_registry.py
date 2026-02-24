#!/usr/bin/env python3
"""
Agent - Represents a Claude agent in a tmux session.

This module provides the Agent class for representing agent state.
Registry operations have been moved to WorkflowRegistry in workflow_registry.py.
"""

from datetime import datetime
from typing import Optional, List, Dict, Any


class Agent:
    """Represents a Claude agent."""

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
        pane_id: Optional[str] = None  # Global tmux pane ID (e.g., "%5")
    ):
        self.session_name = session_name
        self.window_index = window_index
        self.pane_id = pane_id  # Global tmux pane ID (e.g., "%5", "%12")
        self.role = role
        self.pm_window = pm_window
        self.project_path = project_path
        self.status = status  # active, paused, terminated
        self.created_at = created_at or datetime.now().isoformat()
        # Generate agent_id: prefer pane_id, fallback to session:window
        if agent_id:
            self.agent_id = agent_id
        elif pane_id:
            self.agent_id = pane_id
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
        if self.pane_id:
            return self.pane_id
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
        # Include pane_id if set
        if self.pane_id is not None:
            data["pane_id"] = self.pane_id
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
            pane_id=data.get("pane_id")
        )

    @classmethod
    def from_yaml_dict(cls, data: Dict[str, Any], project_path: Optional[str] = None) -> "Agent":
        """
        Create an Agent from a YAML agents.yml entry.

        YAML format:
        ```yaml
        name: developer
        role: developer
        pane_id: "%12"
        session: "myproject"  # display-only metadata
        window: 1             # display-only metadata
        model: sonnet
        ```
        """
        session = data.get("session", "")
        window = data.get("window", 0)
        pane_id = data.get("pane_id")

        return cls(
            session_name=session,
            window_index=window,
            role=data.get("role", "developer"),
            project_path=project_path,
            status="active",
            name=data.get("name"),
            model=data.get("model"),
            pane_id=pane_id
        )

    def to_yaml_dict(self) -> Dict[str, Any]:
        """Convert Agent to a YAML agents.yml entry."""
        entry = {
            "name": self.name or self.role,
            "role": self.role,
            "pane_id": self.pane_id or "",
            "session": self.session_name,
            "window": self.window_index,
            "model": self.model or "sonnet"
        }
        return entry

    def __repr__(self) -> str:
        return f"Agent({self.agent_id}, role={self.role}, status={self.status})"
