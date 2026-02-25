"""Tests for lib/session_registry.py — Agent class."""

from datetime import datetime

import pytest

from lib.session_registry import Agent


class TestAgentInit:
    """Tests for Agent.__init__."""

    def test_basic_creation(self):
        agent = Agent(session_name="sess", window_index=1, role="developer")
        assert agent.session_name == "sess"
        assert agent.window_index == 1
        assert agent.role == "developer"
        assert agent.status == "active"
        assert agent.project_path is None
        assert agent.skills == []
        assert agent.name is None
        assert agent.focus is None
        assert agent.briefing is None
        assert agent.model is None
        assert agent.pane_id is None

    def test_agent_id_from_pane_id(self):
        agent = Agent(session_name="sess", window_index=1, role="dev", pane_id="%5")
        assert agent.agent_id == "%5"

    def test_agent_id_from_session_window(self):
        agent = Agent(session_name="sess", window_index=2, role="dev")
        assert agent.agent_id == "sess:2"

    def test_explicit_agent_id_takes_priority(self):
        agent = Agent(
            session_name="sess", window_index=1, role="dev",
            agent_id="custom-id", pane_id="%5"
        )
        assert agent.agent_id == "custom-id"

    def test_created_at_default(self):
        before = datetime.now().isoformat()[:10]
        agent = Agent(session_name="s", window_index=0, role="dev")
        assert agent.created_at.startswith(before)

    def test_created_at_explicit(self):
        agent = Agent(session_name="s", window_index=0, role="dev", created_at="2025-01-01T00:00:00")
        assert agent.created_at == "2025-01-01T00:00:00"

    def test_all_optional_fields(self):
        agent = Agent(
            session_name="sess",
            window_index=1,
            role="qa",
            project_path="/tmp/proj",
            status="paused",
            agent_id="my-agent",
            name="Tester",
            focus="integration tests",
            skills=["react", "testing"],
            briefing="Focus on API tests",
            model="haiku",
            pane_id="%10",
        )
        assert agent.project_path == "/tmp/proj"
        assert agent.status == "paused"
        assert agent.name == "Tester"
        assert agent.focus == "integration tests"
        assert agent.skills == ["react", "testing"]
        assert agent.briefing == "Focus on API tests"
        assert agent.model == "haiku"
        assert agent.pane_id == "%10"


class TestAgentTarget:
    """Tests for Agent.target property."""

    def test_target_with_pane_id(self):
        agent = Agent(session_name="sess", window_index=1, role="dev", pane_id="%5")
        assert agent.target == "%5"

    def test_target_without_pane_id(self):
        agent = Agent(session_name="sess", window_index=3, role="dev")
        assert agent.target == "sess:3"


class TestAgentToDict:
    """Tests for Agent.to_dict."""

    def test_minimal_agent(self):
        agent = Agent(session_name="sess", window_index=1, role="dev")
        d = agent.to_dict()
        assert d["session_name"] == "sess"
        assert d["window_index"] == 1
        assert d["role"] == "dev"
        assert d["status"] == "active"
        assert "agent_id" in d
        assert "created_at" in d
        assert "project_path" in d
        # Optional fields should be absent when not set
        assert "pane_id" not in d
        assert "name" not in d
        assert "focus" not in d
        assert "skills" not in d
        assert "briefing" not in d
        assert "model" not in d

    def test_full_agent(self):
        agent = Agent(
            session_name="sess",
            window_index=1,
            role="qa",
            project_path="/proj",
            name="Tester",
            focus="e2e",
            skills=["selenium"],
            briefing="Test all flows",
            model="opus",
            pane_id="%7",
        )
        d = agent.to_dict()
        assert d["pane_id"] == "%7"
        assert d["name"] == "Tester"
        assert d["focus"] == "e2e"
        assert d["skills"] == ["selenium"]
        assert d["briefing"] == "Test all flows"
        assert d["model"] == "opus"

    def test_pane_id_none_excluded(self):
        agent = Agent(session_name="s", window_index=0, role="dev", pane_id=None)
        d = agent.to_dict()
        assert "pane_id" not in d

    def test_pane_id_set_included(self):
        agent = Agent(session_name="s", window_index=0, role="dev", pane_id="%0")
        d = agent.to_dict()
        assert d["pane_id"] == "%0"

    def test_empty_skills_excluded(self):
        agent = Agent(session_name="s", window_index=0, role="dev", skills=[])
        d = agent.to_dict()
        assert "skills" not in d

    def test_empty_name_excluded(self):
        agent = Agent(session_name="s", window_index=0, role="dev", name="")
        d = agent.to_dict()
        assert "name" not in d


class TestAgentRepr:
    """Tests for Agent.__repr__."""

    def test_repr_format(self):
        agent = Agent(session_name="sess", window_index=1, role="dev", pane_id="%5")
        r = repr(agent)
        assert "Agent(%5" in r
        assert "role=dev" in r
        assert "status=active" in r

    def test_repr_without_pane_id(self):
        agent = Agent(session_name="sess", window_index=2, role="qa")
        r = repr(agent)
        assert "Agent(sess:2" in r
        assert "role=qa" in r
