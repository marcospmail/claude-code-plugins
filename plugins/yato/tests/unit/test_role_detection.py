"""Tests for hooks/scripts/role_detection.py — agent role detection via identity.yml scanning."""

import os
import sys
from pathlib import Path
from unittest.mock import patch, MagicMock

import pytest
import yaml

# Add hooks/scripts to sys.path so we can import role_detection
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "hooks" / "scripts"))

from role_detection import (
    detect_role,
    find_project_root_from_path,
    find_project_root_from_cwd,
    _get_workflow_session,
    _safe_int,
    _get_workflow_name,
    _get_tmux_session_name,
    _get_tmux_window_pane,
)


# ==================== Helpers ====================


def _make_workflow(tmp_path, workflow_name="001-feature", agents=None, status=None):
    """Create a .workflow directory structure for testing.

    Args:
        tmp_path: pytest tmp_path fixture
        workflow_name: name of the workflow directory
        agents: dict of {agent_name: identity_data}
        status: dict for status.yml content
    """
    wf_dir = tmp_path / ".workflow" / workflow_name
    agents_dir = wf_dir / "agents"
    agents_dir.mkdir(parents=True)

    if status:
        with open(wf_dir / "status.yml", "w") as f:
            yaml.dump(status, f)

    if agents:
        for agent_name, identity_data in agents.items():
            agent_dir = agents_dir / agent_name
            agent_dir.mkdir()
            with open(agent_dir / "identity.yml", "w") as f:
                yaml.dump(identity_data, f)

    return wf_dir


# ==================== _safe_int ====================


class TestSafeInt:
    def test_valid_int(self):
        assert _safe_int(42) == 42

    def test_valid_string(self):
        assert _safe_int("7") == 7

    def test_invalid_string(self):
        assert _safe_int("abc") is None

    def test_none(self):
        assert _safe_int(None) is None

    def test_float(self):
        assert _safe_int(3.9) == 3


# ==================== _get_workflow_session ====================


class TestGetWorkflowSession:
    def test_reads_session_from_status_yml(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        with open(wf_dir / "status.yml", "w") as f:
            yaml.dump({"session": "myproject", "status": "in-progress"}, f)

        result = _get_workflow_session(wf_dir)
        assert result == "myproject"

    def test_returns_none_when_status_yml_missing(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        assert _get_workflow_session(wf_dir) is None

    def test_returns_none_when_no_session_key(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        with open(wf_dir / "status.yml", "w") as f:
            yaml.dump({"status": "in-progress", "title": "test"}, f)

        assert _get_workflow_session(wf_dir) is None

    def test_returns_none_when_session_is_empty(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        with open(wf_dir / "status.yml", "w") as f:
            yaml.dump({"session": "", "status": "in-progress"}, f)

        assert _get_workflow_session(wf_dir) is None

    def test_returns_none_when_yaml_is_invalid(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        with open(wf_dir / "status.yml", "w") as f:
            f.write(": invalid: yaml: [")

        assert _get_workflow_session(wf_dir) is None

    def test_returns_none_when_yaml_is_a_list(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        with open(wf_dir / "status.yml", "w") as f:
            yaml.dump(["not", "a", "dict"], f)

        assert _get_workflow_session(wf_dir) is None

    def test_converts_int_session_to_string(self, tmp_path):
        wf_dir = tmp_path / "wf"
        wf_dir.mkdir()
        with open(wf_dir / "status.yml", "w") as f:
            yaml.dump({"session": 123}, f)

        result = _get_workflow_session(wf_dir)
        assert result == "123"


# ==================== detect_role — no TMUX ====================


class TestDetectRoleNoTmux:
    def test_returns_none_without_tmux_env(self, tmp_path):
        _make_workflow(tmp_path, agents={"developer": {"role": "developer", "pane_id": "%5"}})
        with patch.dict(os.environ, {}, clear=True):
            result = detect_role(project_root=tmp_path)
        assert result is None


# ==================== detect_role — no .workflow ====================


class TestDetectRoleNoWorkflow:
    def test_returns_none_without_workflow_dir(self, tmp_path):
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="mysession"), \
             patch("role_detection._get_tmux_window_pane", return_value=(0, 0)):
            result = detect_role(project_root=tmp_path)
        assert result is None


# ==================== detect_role — pane_id matching with session validation ====================


class TestDetectRolePaneIdSessionValidation:
    """Tests for the core bug fix: pane_id match must also validate session."""

    def test_pane_id_matches_session_matches_returns_role(self, tmp_path):
        """Happy path: pane_id matches AND session matches → return role."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result == "developer"

    def test_pane_id_matches_session_doesnt_match_returns_none(self, tmp_path):
        """THE BUG FIX: pane_id matches but session is different → return None."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "old-project", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="new-project"), \
             patch("role_detection._get_tmux_window_pane", return_value=(0, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_pane_id_matches_no_session_in_status_yml_returns_role(self, tmp_path):
        """Graceful degradation: pane_id matches, status.yml has no session → return role."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"status": "in-progress", "title": "test"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result == "developer"

    def test_pane_id_matches_no_status_yml_returns_role(self, tmp_path):
        """Graceful degradation: pane_id matches, status.yml doesn't exist → return role."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            # No status dict → no status.yml created
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result == "developer"

    def test_pane_id_matches_no_current_session_returns_none(self, tmp_path):
        """When pane_id matches but current session can't be determined, refuse match to avoid false positives."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value=None), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_pane_id_doesnt_match_skips_to_next_agent(self, tmp_path):
        """When pane_id is set but doesn't match, skip this agent entirely (no legacy fallback)."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%99"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None


# ==================== detect_role — multiple agents ====================


class TestDetectRoleMultipleAgents:
    def test_matches_correct_agent_among_multiple(self, tmp_path):
        """With multiple agents, match the one with the correct pane_id."""
        _make_workflow(
            tmp_path,
            agents={
                "developer": {"role": "developer", "pane_id": "%10"},
                "qa": {"role": "qa", "pane_id": "%5"},
                "pm": {"role": "pm", "pane_id": "%3"},
            },
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(2, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result == "qa"

    def test_session_mismatch_rejects_all_agents(self, tmp_path):
        """With session mismatch, none of the agents should match even if pane_id matches."""
        _make_workflow(
            tmp_path,
            agents={
                "developer": {"role": "developer", "pane_id": "%5"},
                "qa": {"role": "qa", "pane_id": "%6"},
            },
            status={"session": "old-project", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="new-project"), \
             patch("role_detection._get_tmux_window_pane", return_value=(0, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None


# ==================== detect_role — legacy fallback (no pane_id) ====================


class TestDetectRoleLegacyFallback:
    def test_legacy_session_window_match_returns_role(self, tmp_path):
        """Legacy identity.yml without pane_id: match by session + window."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "session": "myproject", "window": 1}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result == "developer"

    def test_legacy_session_mismatch_returns_none(self, tmp_path):
        """Legacy identity.yml: session doesn't match → return None."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "session": "other-project", "window": 1}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_legacy_window_mismatch_returns_none(self, tmp_path):
        """Legacy identity.yml: window doesn't match → return None."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "session": "myproject", "window": 2}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_legacy_no_session_in_identity_returns_none(self, tmp_path):
        """Legacy identity.yml without session field → return None."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "window": 1}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None


# ==================== detect_role — role normalization ====================


class TestDetectRoleNormalization:
    def test_role_returned_lowercase(self, tmp_path):
        """Role is always returned in lowercase."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "Developer", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result == "developer"

    def test_empty_role_skipped(self, tmp_path):
        """Identity with empty role is skipped."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None


# ==================== detect_role — workflow scanning ====================


class TestDetectRoleWorkflowScanning:
    def test_uses_workflow_name_env_when_set(self, tmp_path):
        """When WORKFLOW_NAME is set, scan only that workflow."""
        _make_workflow(
            tmp_path,
            workflow_name="002-other",
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        # Also create 001 with a different agent that should NOT be matched
        _make_workflow(
            tmp_path,
            workflow_name="001-old",
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "old-project", "status": "completed"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="002-other"):
            result = detect_role(project_root=tmp_path)
        assert result == "developer"

    def test_falls_back_to_most_recent_numbered_workflow(self, tmp_path):
        """Without WORKFLOW_NAME, scan most recent numbered workflow (highest number)."""
        _make_workflow(
            tmp_path,
            workflow_name="001-old",
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        _make_workflow(
            tmp_path,
            workflow_name="002-new",
            agents={"qa": {"role": "qa", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value=None):
            result = detect_role(project_root=tmp_path)
        assert result == "qa"


# ==================== detect_role — project root discovery ====================


class TestDetectRoleProjectRoot:
    def test_finds_root_from_file_path(self, tmp_path):
        """When file_path is given, find project root by walking up."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5"}},
            status={"session": "myproject", "status": "in-progress"},
        )
        nested_file = tmp_path / "src" / "main.py"
        nested_file.parent.mkdir(parents=True)
        nested_file.touch()

        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(file_path=str(nested_file))
        assert result == "developer"

    def test_returns_none_when_no_project_root_found(self, tmp_path):
        """When no .workflow directory found, return None."""
        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)):
            result = detect_role(file_path=str(tmp_path / "nonexistent" / "file.py"))
        assert result is None


# ==================== detect_role — edge cases ====================


class TestDetectRoleEdgeCases:
    def test_invalid_identity_yml_skipped(self, tmp_path):
        """Malformed identity.yml files are skipped gracefully."""
        wf_dir = tmp_path / ".workflow" / "001-feature" / "agents" / "developer"
        wf_dir.mkdir(parents=True)
        with open(wf_dir / "identity.yml", "w") as f:
            f.write(": invalid: yaml: [")

        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_identity_yml_with_list_content_skipped(self, tmp_path):
        """identity.yml containing a YAML list instead of dict is skipped."""
        wf_dir = tmp_path / ".workflow" / "001-feature" / "agents" / "developer"
        wf_dir.mkdir(parents=True)
        with open(wf_dir / "identity.yml", "w") as f:
            yaml.dump(["not", "a", "dict"], f)

        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_no_agents_dir_returns_none(self, tmp_path):
        """Workflow exists but has no agents/ directory → return None."""
        wf_dir = tmp_path / ".workflow" / "001-feature"
        wf_dir.mkdir(parents=True)

        env = {"TMUX": "/tmp/tmux-501/default,12345,0", "TMUX_PANE": "%5"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        assert result is None

    def test_no_tmux_pane_env_uses_legacy_only(self, tmp_path):
        """When TMUX_PANE is not set, pane_id matching is skipped; only legacy fallback works."""
        _make_workflow(
            tmp_path,
            agents={"developer": {"role": "developer", "pane_id": "%5", "session": "myproject", "window": 1}},
            status={"session": "myproject", "status": "in-progress"},
        )
        # TMUX_PANE is missing — pane_id comparison (identity_pane_id && current_pane_id) will be falsy
        # so it falls through to legacy fallback
        env = {"TMUX": "/tmp/tmux-501/default,12345,0"}
        with patch.dict(os.environ, env, clear=True), \
             patch("role_detection._get_tmux_session_name", return_value="myproject"), \
             patch("role_detection._get_tmux_window_pane", return_value=(1, 0)), \
             patch("role_detection._get_workflow_name", return_value="001-feature"):
            result = detect_role(project_root=tmp_path)
        # pane_id is set in identity but current_pane_id is None, so the if condition
        # `if identity_pane_id and current_pane_id:` is False → falls to legacy
        assert result == "developer"


# ==================== find_project_root_from_path ====================


class TestFindProjectRootFromPath:
    def test_finds_root_with_workflow_dir(self, tmp_path):
        (tmp_path / ".workflow").mkdir()
        nested = tmp_path / "src" / "file.py"
        nested.parent.mkdir()
        nested.touch()
        assert find_project_root_from_path(str(nested)) == tmp_path

    def test_returns_none_without_workflow(self, tmp_path):
        nested = tmp_path / "src" / "file.py"
        nested.parent.mkdir()
        nested.touch()
        assert find_project_root_from_path(str(nested)) is None


# ==================== find_project_root_from_cwd ====================


class TestFindProjectRootFromCwd:
    def test_uses_hook_cwd_env(self, tmp_path):
        (tmp_path / ".workflow").mkdir()
        sub = tmp_path / "sub"
        sub.mkdir()
        with patch.dict(os.environ, {"HOOK_CWD": str(sub)}):
            result = find_project_root_from_cwd()
        assert result == tmp_path

    def test_returns_none_without_workflow(self, tmp_path):
        with patch.dict(os.environ, {"HOOK_CWD": str(tmp_path)}):
            result = find_project_root_from_cwd()
        assert result is None
