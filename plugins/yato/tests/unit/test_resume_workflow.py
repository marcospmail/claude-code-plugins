"""Tests for resume-workflow.sh agent window duplication bug.

These tests verify that resuming a workflow reuses existing agent windows
instead of creating duplicates. The bug: resume-workflow.sh unconditionally
calls `tmux new-window` for every agent in agents.yml without checking if
a window with that name already exists.

Tests use an isolated tmux socket to avoid interfering with the real tmux.
"""

import json
import os
import subprocess
import textwrap

import pytest
import yaml


YATO_ROOT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", ".."))
RESUME_SCRIPT = os.path.join(YATO_ROOT, "bin", "resume-workflow.sh")
TMUX_SOCKET = "yato-unit-test-resume"


def tmux(*args, check=True):
    """Run tmux command on the isolated test socket."""
    cmd = ["tmux", "-L", TMUX_SOCKET] + list(args)
    result = subprocess.run(cmd, capture_output=True, text=True, timeout=10)
    if check and result.returncode != 0:
        raise subprocess.CalledProcessError(
            result.returncode, cmd, result.stdout, result.stderr
        )
    return result


def tmux_list_windows(session):
    """List windows in a session, returning list of (index, name) tuples."""
    result = tmux(
        "list-windows", "-t", session,
        "-F", "#{window_index}:#{window_name}",
        check=False,
    )
    if result.returncode != 0:
        return []
    windows = []
    for line in result.stdout.strip().splitlines():
        if ":" in line:
            idx, name = line.split(":", 1)
            windows.append((int(idx), name))
    return windows


def tmux_get_pane_id(session, window):
    """Get the global pane ID for a window."""
    result = tmux(
        "display-message", "-t", f"{session}:{window}",
        "-p", "#{pane_id}", check=False,
    )
    if result.returncode != 0:
        return None
    return result.stdout.strip()


@pytest.fixture
def tmux_session():
    """Create an isolated tmux session and clean up after test."""
    session_name = f"test-resume-{os.getpid()}"
    # Kill any leftover session
    tmux("kill-session", "-t", session_name, check=False)
    yield session_name
    # Cleanup
    tmux("kill-session", "-t", session_name, check=False)
    tmux("kill-server", check=False)


@pytest.fixture
def workflow_project(tmp_path):
    """Create a minimal project with workflow structure for resume testing."""
    project = tmp_path / "project"
    project.mkdir()

    wf_dir = project / ".workflow" / "001-test-feature"
    wf_dir.mkdir(parents=True)

    # Create status.yml
    status = {
        "status": "in-progress",
        "title": "Test Feature",
        "initial_request": "Build test feature",
        "folder": str(wf_dir),
        "checkin_interval_minutes": 5,
        "created_at": "2026-01-01T00:00:00Z",
        "session": "",
    }
    with open(wf_dir / "status.yml", "w") as f:
        f.write("# Workflow Status\n")
        yaml.dump(status, f, default_flow_style=False)

    # Create agents.yml with 2 agents
    agents_content = textwrap.dedent("""\
        # Agent Registry
        pm:
          name: pm
          role: pm
          session: ""
          window: 0
          pane: 1
          model: opus

        agents:
          - name: developer
            role: developer
            session: ""
            window: 1
            model: sonnet
          - name: qa
            role: qa
            session: ""
            window: 2
            model: sonnet
    """)
    (wf_dir / "agents.yml").write_text(agents_content)

    # Create tasks.json with pending tasks (needed by checkin logic)
    tasks = {
        "tasks": [
            {"id": "T1", "subject": "Implement", "description": "Do it",
             "agent": "developer", "status": "pending", "blockedBy": [], "blocks": []},
        ]
    }
    (wf_dir / "tasks.json").write_text(json.dumps(tasks))

    # Create checkins.json
    (wf_dir / "checkins.json").write_text('{"checkins": [], "daemon_pid": null}')

    # Create agent directories with identity.yml
    for agent_name, role in [("pm", "pm"), ("developer", "developer"), ("qa", "qa")]:
        agent_dir = wf_dir / "agents" / agent_name
        agent_dir.mkdir(parents=True)
        identity = {
            "name": agent_name,
            "role": role,
            "model": "sonnet" if agent_name != "pm" else "opus",
            "window": "",
            "session": "",
            "workflow": "001-test-feature",
        }
        with open(agent_dir / "identity.yml", "w") as f:
            yaml.dump(identity, f, default_flow_style=False)
        (agent_dir / "instructions.md").write_text(f"# {agent_name} instructions\n")

    return project


def run_resume(project_path, workflow_name, env_extra=None):
    """Run resume-workflow.sh and return the result."""
    env = os.environ.copy()
    env["TMUX_SOCKET"] = TMUX_SOCKET
    # Remove TMUX so the script doesn't think we're inside tmux
    env.pop("TMUX", None)
    if env_extra:
        env.update(env_extra)
    result = subprocess.run(
        ["bash", RESUME_SCRIPT, str(project_path), workflow_name],
        capture_output=True, text=True, timeout=120,
        env=env,
    )
    return result


class TestResumeWindowDeduplication:
    """Tests for the window deduplication bug fix."""

    def test_resume_with_existing_windows_does_not_create_duplicates(
        self, tmux_session, workflow_project
    ):
        """When agent windows already exist, resume should reuse them, not create new ones.

        This is the core bug: resume-workflow.sh creates duplicate windows because
        it calls `tmux new-window` unconditionally at line 274.
        """
        project = workflow_project
        wf_name = "001-test-feature"

        # Compute what the resume script will name the session
        project_slug = os.path.basename(str(project)).lower().replace(".", "-").replace("_", "-").replace(" ", "-")
        resume_session = f"{project_slug}_{wf_name}"

        # Create the session and pre-existing agent windows (simulating a previous resume)
        tmux("new-session", "-d", "-s", resume_session, "-c", str(project))
        tmux("rename-window", "-t", f"{resume_session}:0", "Orchestrator")
        # Split for PM layout
        tmux("split-window", "-t", f"{resume_session}:0.0", "-v", "-b", "-p", "20", "-c", str(project))
        # Create agent windows that already exist
        tmux("new-window", "-t", resume_session, "-n", "developer", "-c", str(project))
        tmux("new-window", "-t", resume_session, "-n", "qa", "-c", str(project))

        # Record initial state
        initial_windows = tmux_list_windows(resume_session)
        initial_window_count = len(initial_windows)

        assert initial_window_count == 3, f"Expected 3 windows before resume, got {initial_window_count}"
        assert any(name == "developer" for _, name in initial_windows)
        assert any(name == "qa" for _, name in initial_windows)

        # Run resume
        run_resume(project, wf_name)

        # After resume, should still have exactly 3 windows (no duplicates)
        final_windows = tmux_list_windows(resume_session)
        final_window_count = len(final_windows)
        window_names = [name for _, name in final_windows]

        # Count how many developer and qa windows exist
        dev_count = sum(1 for name in window_names if name == "developer")
        qa_count = sum(1 for name in window_names if name == "qa")

        assert dev_count == 1, (
            f"Expected 1 'developer' window, got {dev_count}. "
            f"Windows: {final_windows}. Resume created duplicates!"
        )
        assert qa_count == 1, (
            f"Expected 1 'qa' window, got {qa_count}. "
            f"Windows: {final_windows}. Resume created duplicates!"
        )
        assert final_window_count == initial_window_count, (
            f"Expected {initial_window_count} windows after resume, got {final_window_count}. "
            f"Before: {initial_windows}, After: {final_windows}"
        )

    def test_resume_with_missing_windows_creates_only_missing(
        self, tmux_session, workflow_project
    ):
        """When some agent windows exist but others don't, only create the missing ones."""
        project = workflow_project
        wf_name = "001-test-feature"

        project_slug = os.path.basename(str(project)).lower().replace(".", "-").replace("_", "-").replace(" ", "-")
        resume_session = f"{project_slug}_{wf_name}"

        # Create session with only the developer window (qa is missing)
        tmux("new-session", "-d", "-s", resume_session, "-c", str(project))
        tmux("rename-window", "-t", f"{resume_session}:0", "Orchestrator")
        tmux("split-window", "-t", f"{resume_session}:0.0", "-v", "-b", "-p", "20", "-c", str(project))
        tmux("new-window", "-t", resume_session, "-n", "developer", "-c", str(project))

        initial_windows = tmux_list_windows(resume_session)
        assert len(initial_windows) == 2  # Orchestrator + developer

        # Run resume
        run_resume(project, wf_name)

        # Should now have 3 windows: Orchestrator + developer (reused) + qa (new)
        final_windows = tmux_list_windows(resume_session)
        window_names = [name for _, name in final_windows]

        dev_count = sum(1 for name in window_names if name == "developer")
        qa_count = sum(1 for name in window_names if name == "qa")

        assert dev_count == 1, (
            f"Expected 1 'developer' window, got {dev_count}. Windows: {final_windows}"
        )
        assert qa_count == 1, (
            f"Expected 1 'qa' window (newly created), got {qa_count}. Windows: {final_windows}"
        )
        assert len(final_windows) == 3, (
            f"Expected 3 windows total, got {len(final_windows)}. Windows: {final_windows}"
        )

    def test_resume_with_no_existing_windows_creates_all(
        self, tmux_session, workflow_project
    ):
        """When no agent windows exist (fresh session), create all of them."""
        project = workflow_project
        wf_name = "001-test-feature"

        project_slug = os.path.basename(str(project)).lower().replace(".", "-").replace("_", "-").replace(" ", "-")
        resume_session = f"{project_slug}_{wf_name}"

        # Don't pre-create anything — let resume create the session from scratch
        run_resume(project, wf_name)

        # Should have Orchestrator + developer + qa = 3 windows minimum
        final_windows = tmux_list_windows(resume_session)
        window_names = [name for _, name in final_windows]

        assert "developer" in window_names, f"Missing developer window. Windows: {final_windows}"
        assert "qa" in window_names, f"Missing qa window. Windows: {final_windows}"

        dev_count = sum(1 for name in window_names if name == "developer")
        qa_count = sum(1 for name in window_names if name == "qa")
        assert dev_count == 1, f"Expected exactly 1 developer window, got {dev_count}"
        assert qa_count == 1, f"Expected exactly 1 qa window, got {qa_count}"


class TestResumeAgentsYmlDeduplication:
    """Tests for agents.yml update logic — no duplicate entries."""

    def test_agents_yml_not_duplicated_on_resume(
        self, tmux_session, workflow_project
    ):
        """agents.yml should update existing entries in-place, not append duplicates."""
        project = workflow_project
        wf_name = "001-test-feature"
        agents_file = project / ".workflow" / wf_name / "agents.yml"

        # Run resume twice
        run_resume(project, wf_name)

        project_slug = os.path.basename(str(project)).lower().replace(".", "-").replace("_", "-").replace(" ", "-")
        resume_session = f"{project_slug}_{wf_name}"

        # Run resume again — this should NOT duplicate entries
        run_resume(project, wf_name)

        # Parse agents.yml
        with open(agents_file) as f:
            data = yaml.safe_load(f)

        agents = data.get("agents", [])
        agent_names = [a["name"] for a in agents]

        # Each agent should appear exactly once
        assert agent_names.count("developer") == 1, (
            f"'developer' appears {agent_names.count('developer')} times in agents.yml. "
            f"Agents: {agent_names}"
        )
        assert agent_names.count("qa") == 1, (
            f"'qa' appears {agent_names.count('qa')} times in agents.yml. "
            f"Agents: {agent_names}"
        )

    def test_agents_yml_pane_ids_updated_on_resume(
        self, tmux_session, workflow_project
    ):
        """agents.yml should have updated pane_id values after resume."""
        project = workflow_project
        wf_name = "001-test-feature"
        agents_file = project / ".workflow" / wf_name / "agents.yml"

        # Run resume
        run_resume(project, wf_name)

        # Parse agents.yml
        with open(agents_file) as f:
            data = yaml.safe_load(f)

        agents = data.get("agents", [])
        for agent in agents:
            pane_id = agent.get("pane_id", "")
            # pane_id should be a tmux global pane ID like %N
            assert pane_id and pane_id.startswith("%"), (
                f"Agent '{agent['name']}' has invalid pane_id: '{pane_id}'. "
                f"Expected format: %N"
            )

    def test_identity_yml_updated_on_resume(
        self, tmux_session, workflow_project
    ):
        """Identity files should have updated pane_id values after resume."""
        project = workflow_project
        wf_name = "001-test-feature"

        # Run resume
        run_resume(project, wf_name)

        for agent_name in ["developer", "qa"]:
            identity_file = (
                project / ".workflow" / wf_name / "agents" / agent_name / "identity.yml"
            )
            with open(identity_file) as f:
                data = yaml.safe_load(f)

            pane_id = data.get("pane_id", "")
            assert pane_id and pane_id.startswith("%"), (
                f"Agent '{agent_name}' identity.yml has invalid pane_id: '{pane_id}'"
            )
