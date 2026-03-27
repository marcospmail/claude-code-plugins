"""Shared fixtures for Yato unit tests."""

import pytest
import yaml


@pytest.fixture
def tmp_project(tmp_path):
    """Create a temporary project directory with .workflow structure."""
    project = tmp_path / "project"
    project.mkdir()
    return project


@pytest.fixture
def tmp_workflow(tmp_project):
    """Create a temporary workflow directory with status.yml and agents.yml."""
    workflow_dir = tmp_project / ".workflow" / "001-test-feature"
    workflow_dir.mkdir(parents=True)

    # Create status.yml
    status_data = {
        "status": "in-progress",
        "title": "Test Feature",
        "initial_request": "Build test feature",
        "folder": "001-test-feature",
        "checkin_interval_minutes": 5,
        "created_at": "2026-01-01T00:00:00Z",
        "session": "test-session",
        "agent_message_suffix": "",
        "checkin_message_suffix": "",
        "agent_to_pm_message_suffix": "",
        "user_to_pm_message_suffix": "",
    }
    status_file = workflow_dir / "status.yml"
    with open(status_file, "w") as f:
        f.write("# Workflow Status\n")
        yaml.dump(status_data, f, default_flow_style=False)

    # Create agents directory
    (workflow_dir / "agents" / "pm").mkdir(parents=True)

    return workflow_dir


@pytest.fixture
def tmp_workflow_with_agents(tmp_workflow):
    """Create a workflow with agents.yml populated."""
    agents_data = {
        "pm": {
            "name": "pm",
            "role": "pm",
            "pane_id": "%5",
            "session": "test-session",
            "window": 0,
            "model": "opus",
        },
        "agents": [
            {
                "name": "developer",
                "role": "developer",
                "pane_id": "%6",
                "session": "test-session",
                "window": 1,
                "model": "sonnet",
            },
            {
                "name": "qa",
                "role": "qa",
                "pane_id": "%7",
                "session": "test-session",
                "window": 2,
                "model": "haiku",
            },
        ],
    }
    agents_file = tmp_workflow / "agents.yml"
    with open(agents_file, "w") as f:
        yaml.dump(agents_data, f, default_flow_style=False)

    return tmp_workflow


@pytest.fixture
def sample_tasks_data():
    """Return sample tasks.json data."""
    return {
        "tasks": [
            {
                "id": "T1",
                "subject": "Implement user auth",
                "description": "Add login/signup flows",
                "agent": "developer",
                "status": "pending",
                "blockedBy": [],
                "blocks": ["T2"],
            },
            {
                "id": "T2",
                "subject": "Write auth tests",
                "description": "Unit and integration tests for auth",
                "agent": "qa",
                "status": "pending",
                "blockedBy": ["T1"],
                "blocks": [],
            },
            {
                "id": "T3",
                "subject": "Setup CI pipeline",
                "description": "Configure GitHub Actions",
                "agent": "developer",
                "status": "completed",
                "blockedBy": [],
                "blocks": [],
                "completed_at": "2026-01-01T12:00:00",
            },
        ]
    }


@pytest.fixture
def sample_config_content():
    """Return sample defaults.conf content."""
    return """# Yato Config
DEFAULT_SESSION="yato"
DEFAULT_ORCHESTRATOR_WINDOW="0"
LOG_DIR=".yato/logs"
DEFAULT_CHECKIN_MINUTES=15
PM_TO_AGENTS_SUFFIX="reminder for agents"
AGENTS_TO_PM_SUFFIX="reminder for pm"
CHECKIN_TO_PM_SUFFIX="reminder for checkin"
USER_TO_PM_SUFFIX="reminder for user"
"""


@pytest.fixture
def tmp_config(tmp_path, sample_config_content):
    """Create a temporary config/defaults.conf."""
    config_dir = tmp_path / "config"
    config_dir.mkdir()
    config_file = config_dir / "defaults.conf"
    config_file.write_text(sample_config_content)
    return config_file


@pytest.fixture
def clean_env(monkeypatch):
    """Remove yato-related env vars for clean test state."""
    for var in [
        "YATO_PATH", "TMUX", "TMUX_SOCKET", "WORKFLOW_NAME",
        "_YATO_WORKFLOW_NAME",
    ]:
        monkeypatch.delenv(var, raising=False)
    return monkeypatch


@pytest.fixture
def reset_config_cache():
    """Reset the config module's cache before each test."""
    import lib.config as config_mod
    config_mod._config_cache = None
    yield
    config_mod._config_cache = None
