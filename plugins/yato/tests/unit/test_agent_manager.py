"""Tests for lib/agent_manager.py — agent creation and lifecycle management."""

import os
import runpy
import sys
import subprocess
from pathlib import Path
from unittest.mock import MagicMock, patch, call

import pytest
import yaml

from lib.agent_manager import AgentManager, init_agent_files, create_agent


# ==================== AgentManager.__init__ ====================


class TestAgentManagerInit:
    def test_default_paths(self):
        mgr = AgentManager()
        assert mgr.yato_path is not None
        assert mgr.templates_dir == mgr.yato_path / "lib" / "templates"

    def test_with_workflow_path(self, tmp_path):
        mgr = AgentManager(workflow_path=str(tmp_path / "wf"))
        assert mgr.workflow_path == tmp_path / "wf"

    def test_with_yato_path(self, tmp_path):
        mgr = AgentManager(yato_path=str(tmp_path))
        assert mgr.yato_path == tmp_path

    def test_jinja_env_set_when_templates_exist(self):
        mgr = AgentManager()
        # Templates should exist in the real project
        if mgr.templates_dir.exists():
            assert mgr.jinja_env is not None

    def test_jinja_env_none_when_templates_missing(self, tmp_path):
        mgr = AgentManager(yato_path=str(tmp_path))
        assert mgr.jinja_env is None


# ==================== _get_default_model ====================


class TestGetDefaultModel:
    def test_pm_gets_opus(self):
        mgr = AgentManager()
        assert mgr._get_default_model("pm") == "opus"

    def test_code_reviewer_gets_opus(self):
        mgr = AgentManager()
        assert mgr._get_default_model("code-reviewer") == "opus"

    def test_security_reviewer_gets_opus(self):
        mgr = AgentManager()
        assert mgr._get_default_model("security-reviewer") == "opus"

    def test_unknown_role_gets_sonnet(self):
        mgr = AgentManager()
        assert mgr._get_default_model("developer") == "sonnet"
        assert mgr._get_default_model("unknown") == "sonnet"


# ==================== _get_role_config ====================


class TestGetRoleConfig:
    def test_exact_match_developer(self):
        mgr = AgentManager()
        config = mgr._get_role_config("developer")
        assert config["can_modify_code"] is True
        assert "Implementation" in config["purpose"]

    def test_exact_match_qa(self):
        mgr = AgentManager()
        config = mgr._get_role_config("qa")
        assert config["can_modify_code"] == "test-only"

    def test_exact_match_pm(self):
        mgr = AgentManager()
        config = mgr._get_role_config("pm")
        assert config["can_modify_code"] is False

    def test_partial_match_my_developer(self):
        mgr = AgentManager()
        config = mgr._get_role_config("my-developer")
        assert config["can_modify_code"] is True

    def test_partial_match_with_dev(self):
        mgr = AgentManager()
        config = mgr._get_role_config("lead-dev")
        assert config["can_modify_code"] is True

    def test_unknown_role(self):
        mgr = AgentManager()
        config = mgr._get_role_config("unknown-role")
        assert config["can_modify_code"] is False
        assert "Support" in config["purpose"]

    def test_case_insensitive(self):
        mgr = AgentManager()
        config = mgr._get_role_config("Developer")
        assert config["can_modify_code"] is True


# ==================== _render_template ====================


class TestRenderTemplate:
    def test_no_jinja_env_raises(self, tmp_path):
        mgr = AgentManager(yato_path=str(tmp_path))
        with pytest.raises(RuntimeError, match="Templates directory not found"):
            mgr._render_template("some.j2", {})

    def test_renders_with_real_templates(self):
        mgr = AgentManager()
        if mgr.jinja_env is None:
            pytest.skip("No templates directory available")
        result = mgr._render_template("agent_tasks.md.j2", {})
        assert isinstance(result, str)
        assert len(result) > 0


# ==================== init_agent_files ====================


class TestInitAgentFiles:
    def test_creates_all_files_developer(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "mydev", "developer", "sonnet", "001-test-feature"
        )
        assert result is not None
        agent_dir = Path(result)
        assert (agent_dir / "identity.yml").exists()
        assert (agent_dir / "instructions.md").exists()
        assert (agent_dir / "constraints.md").exists()
        assert (agent_dir / "CLAUDE.md").exists()
        assert (agent_dir / "agent-tasks.md").exists()
        # Developer should NOT have planning-briefing.md
        assert not (agent_dir / "planning-briefing.md").exists()

    def test_pm_gets_planning_briefing(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "pm", "pm", "opus", "001-test-feature"
        )
        assert result is not None
        agent_dir = Path(result)
        assert (agent_dir / "planning-briefing.md").exists()

    def test_pm_constraints_differ_from_agent(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        pm_dir = mgr.init_agent_files(
            str(project), "pm", "pm", "opus", "001-test-feature"
        )
        dev_dir = mgr.init_agent_files(
            str(project), "dev", "developer", "sonnet", "001-test-feature"
        )
        pm_constraints = Path(pm_dir) / "constraints.md"
        dev_constraints = Path(dev_dir) / "constraints.md"
        assert "PM Constraints" in pm_constraints.read_text()
        assert "PM Constraints" not in dev_constraints.read_text()

    def test_qa_role(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        result = mgr.init_agent_files(
            str(project), "qa", "qa", "haiku", "001-test-feature"
        )
        assert result is not None
        identity = yaml.safe_load((Path(result) / "identity.yml").read_text())
        assert identity is not None

    def test_no_workflow_returns_none(self, tmp_project, capsys):
        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value=None):
            result = mgr.init_agent_files(str(tmp_project), "dev", "developer")
        assert result is None

    def test_auto_detects_workflow(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature"):
            result = mgr.init_agent_files(str(project), "dev2", "developer")
        assert result is not None


# ==================== _resolve_agent_name ====================


class TestResolveAgentName:
    def test_custom_name_used_as_is(self):
        mgr = AgentManager()
        result = mgr._resolve_agent_name("developer", "MyCustomDev", "/tmp")
        assert result == "mycustomdev"

    def test_no_project_path_returns_base(self):
        mgr = AgentManager()
        result = mgr._resolve_agent_name("qa", None, None)
        assert result == "qa"

    @patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=None)
    def test_no_workflow_returns_base(self, mock_wf):
        mgr = AgentManager()
        result = mgr._resolve_agent_name("qa", None, "/tmp/proj")
        assert result == "qa"

    def test_no_existing_agents_returns_base(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        # agents.yml doesn't exist yet
        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("developer", None, str(project))
        assert result == "developer"

    def test_one_existing_renames_to_numbered(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm"},
            "agents": [{"name": "qa", "role": "qa"}],
        }))
        # Also create the agent directory for rename
        (tmp_workflow / "agents" / "qa").mkdir(parents=True, exist_ok=True)
        (tmp_workflow / "agents" / "qa" / "identity.yml").write_text("name: qa\n")
        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("qa", None, str(project))
        assert result == "qa-2"

    def test_multiple_existing_finds_next(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm"},
            "agents": [
                {"name": "qa-1", "role": "qa"},
                {"name": "qa-2", "role": "qa"},
            ],
        }))
        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("qa", None, str(project))
        assert result == "qa-3"


# ==================== _rename_agent ====================


class TestRenameAgent:
    def test_renames_in_agents_yml_and_directory(self, tmp_workflow):
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm"},
            "agents": [{"name": "qa", "role": "qa"}],
        }))
        agent_dir = tmp_workflow / "agents" / "qa"
        agent_dir.mkdir(parents=True, exist_ok=True)
        (agent_dir / "identity.yml").write_text("name: qa\nrole: qa\n")

        mgr = AgentManager()
        project = tmp_workflow.parent.parent
        mgr._rename_agent(str(project), tmp_workflow, "qa", "qa-1", "qa")

        # Check agents.yml updated
        data = yaml.safe_load(agents_file.read_text())
        assert data["agents"][0]["name"] == "qa-1"
        # Check directory renamed
        assert (tmp_workflow / "agents" / "qa-1").exists()
        assert not (tmp_workflow / "agents" / "qa").exists()
        # Check identity.yml updated
        content = (tmp_workflow / "agents" / "qa-1" / "identity.yml").read_text()
        assert 'name: "qa-1"' in content


# ==================== create_agent ====================


class TestCreateAgent:
    @patch("lib.agent_manager.time.sleep")
    @patch("lib.agent_manager.send_message")
    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_with_session_creates_window(
        self, mock_add, mock_wf, mock_tmux, mock_run, mock_send, mock_sleep, tmp_workflow
    ):
        project = tmp_workflow.parent.parent
        # has-session succeeds
        mock_run.side_effect = [
            MagicMock(returncode=0),  # has-session
            MagicMock(returncode=0, stdout="1:%10"),  # new-window
            MagicMock(returncode=0),  # send-keys (claude start)
        ]
        mgr = AgentManager()
        result = mgr.create_agent(
            session="sess",
            role="developer",
            project_path=str(project),
            model="sonnet",
        )
        assert result is not None
        assert result["role"] == "developer"
        assert result["pane_id"] == "%10"
        mock_add.assert_called_once()

    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_without_session_files_only(
        self, mock_add, mock_wf, mock_tmux, mock_run, tmp_workflow
    ):
        project = tmp_workflow.parent.parent
        mock_run.return_value = MagicMock(returncode=1)  # has-session fails
        mgr = AgentManager()
        result = mgr.create_agent(
            session="nonexistent",
            role="developer",
            project_path=str(project),
            start_claude=False,
            send_brief=False,
        )
        assert result is not None
        assert result["role"] == "developer"

    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_no_start_no_brief(
        self, mock_add, mock_wf, mock_tmux, mock_run, tmp_workflow
    ):
        project = tmp_workflow.parent.parent
        mock_run.side_effect = [
            MagicMock(returncode=0),  # has-session
            MagicMock(returncode=0, stdout="1:%10"),  # new-window
        ]
        mgr = AgentManager()
        result = mgr.create_agent(
            session="sess",
            role="developer",
            project_path=str(project),
            start_claude=False,
            send_brief=False,
        )
        assert result is not None
        # Only 2 subprocess calls (has-session + new-window), no claude start
        assert mock_run.call_count == 2

    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_window_creation_failure(self, mock_add, mock_wf, mock_tmux, mock_run, tmp_workflow):
        project = tmp_workflow.parent.parent
        mock_run.side_effect = [
            MagicMock(returncode=0),  # has-session
            MagicMock(returncode=1, stderr="error"),  # new-window fails
        ]
        mgr = AgentManager()
        result = mgr.create_agent(
            session="sess",
            role="developer",
            project_path=str(project),
        )
        assert result is None


# ==================== _send_agent_briefing ====================


class TestSendAgentBriefing:
    @patch("lib.agent_manager.send_message")
    def test_code_restriction_for_non_code_roles(self, mock_send, tmp_workflow):
        mgr = AgentManager()
        mgr._send_agent_briefing(
            agent_id="%5",
            role="code-reviewer",
            name="reviewer",
            session="s",
            window_index=1,
            project_path=str(tmp_workflow.parent.parent),
            workflow_name="001-test-feature",
        )
        mock_send.assert_called_once()
        msg = mock_send.call_args[0][1]
        assert "CODE MODIFICATION RESTRICTION" in msg

    @patch("lib.agent_manager.send_message")
    def test_no_restriction_for_developers(self, mock_send, tmp_workflow):
        mgr = AgentManager()
        mgr._send_agent_briefing(
            agent_id="%5",
            role="developer",
            name="dev",
            session="s",
            window_index=1,
            project_path=str(tmp_workflow.parent.parent),
            workflow_name="001-test-feature",
        )
        mock_send.assert_called_once()
        msg = mock_send.call_args[0][1]
        assert "CODE MODIFICATION RESTRICTION" not in msg


# ==================== create_team ====================


class TestCreateTeam:
    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_creates_multiple_agents(self, mock_add, mock_wf, mock_tmux, mock_run, tmp_workflow):
        project = tmp_workflow.parent.parent
        mock_run.return_value = MagicMock(returncode=1)  # no session
        mgr = AgentManager()
        agents = [
            {"role": "developer", "name": "dev1"},
            {"role": "qa", "name": "qa1"},
        ]
        results = mgr.create_team("sess", agents, project_path=str(project))
        assert len(results) == 2


# ==================== Module-level functions ====================


class TestModuleLevelFunctions:
    def test_init_agent_files_wrapper(self, tmp_workflow):
        project = tmp_workflow.parent.parent
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature"):
            result = init_agent_files(str(project), "dev3", "developer")
        assert result is not None

    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_create_agent_wrapper(self, mock_add, mock_wf, mock_tmux, mock_run, tmp_workflow):
        project = tmp_workflow.parent.parent
        mock_run.return_value = MagicMock(returncode=1)
        result = create_agent(
            "sess", "developer",
            project_path=str(project),
            start_claude=False,
            send_brief=False,
        )
        assert result is not None


# ==================== _resolve_agent_name edge cases ====================


class TestResolveAgentNameEdgeCases:
    def test_yaml_exception_returns_base(self, tmp_workflow):
        """Corrupt agents.yml causes yaml.safe_load to raise, returns base_name (lines 470-471)."""
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(":\n  - :\n  invalid: [yaml: {{{}}")

        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("developer", None, str(project))
        assert result == "developer"

    def test_no_agents_key_returns_base(self, tmp_workflow):
        """agents.yml has data but no 'agents' key, returns base_name (line 474)."""
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({"pm": {"name": "pm"}}))

        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("developer", None, str(project))
        assert result == "developer"

    def test_agents_empty_list_returns_base(self, tmp_workflow):
        """agents.yml has agents: [] (empty list), returns base_name (line 474)."""
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({"agents": []}))

        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("developer", None, str(project))
        assert result == "developer"

    def test_no_same_role_returns_base(self, tmp_workflow):
        """Agents exist but none match the role, returns base_name (line 483)."""
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "agents": [{"name": "qa", "role": "qa"}],
        }))

        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("developer", None, str(project))
        assert result == "developer"

    def test_invalid_numbered_name_skipped(self, tmp_workflow):
        """Agent named 'qa-abc' has ValueError in int parse, gets skipped (lines 502-503)."""
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "agents": [
                {"name": "qa-abc", "role": "qa"},
                {"name": "qa-2", "role": "qa"},
            ],
        }))

        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("qa", None, str(project))
        # max_num=2 from qa-2, qa-abc skipped, next is qa-3
        assert result == "qa-3"

    def test_unnumbered_existing_base_name(self, tmp_workflow):
        """Agent named exactly 'qa' alongside 'qa-1' hits the unnumbered pass branch (lines 504-506)."""
        project = tmp_workflow.parent.parent
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "agents": [
                {"name": "qa", "role": "qa"},
                {"name": "qa-1", "role": "qa"},
            ],
        }))

        mgr = AgentManager()
        with patch("lib.agent_manager.WorkflowOps.get_current_workflow_path", return_value=tmp_workflow):
            result = mgr._resolve_agent_name("qa", None, str(project))
        # max_num=1 from qa-1, 'qa' hits unnumbered pass, next is qa-2
        assert result == "qa-2"


# ==================== _rename_agent disk rename ====================


class TestRenameAgentDiskRename:
    @patch("lib.agent_manager.WorkflowOps._write_agents_yml", side_effect=OSError("disk full"))
    def test_write_agents_yml_exception_silenced(self, mock_write, tmp_workflow):
        """When _write_agents_yml raises, exception is caught and silenced (lines 526-527)."""
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm"},
            "agents": [{"name": "dev", "role": "developer"}],
        }))
        old_dir = tmp_workflow / "agents" / "dev"
        old_dir.mkdir(parents=True, exist_ok=True)
        (old_dir / "identity.yml").write_text("name: dev\nrole: developer\n")

        mgr = AgentManager()
        project = tmp_workflow.parent.parent
        # Should not raise despite _write_agents_yml failing
        mgr._rename_agent(str(project), tmp_workflow, "dev", "dev-1", "developer")

        # agents.yml was NOT updated (write failed), but directory rename still happened
        new_dir = tmp_workflow / "agents" / "dev-1"
        assert new_dir.exists()
        mock_write.assert_called_once()

    def test_directory_rename_on_disk(self, tmp_workflow):
        """Agent directory is renamed on disk when old_dir exists (lines 526-527)."""
        agents_file = tmp_workflow / "agents.yml"
        agents_file.write_text(yaml.dump({
            "pm": {"name": "pm", "role": "pm"},
            "agents": [{"name": "dev", "role": "developer"}],
        }))
        old_dir = tmp_workflow / "agents" / "dev"
        old_dir.mkdir(parents=True, exist_ok=True)
        (old_dir / "identity.yml").write_text("name: dev\nrole: developer\n")
        (old_dir / "instructions.md").write_text("# Instructions\n")

        mgr = AgentManager()
        project = tmp_workflow.parent.parent
        mgr._rename_agent(str(project), tmp_workflow, "dev", "dev-1", "developer")

        new_dir = tmp_workflow / "agents" / "dev-1"
        assert new_dir.exists()
        assert not old_dir.exists()
        assert (new_dir / "instructions.md").exists()
        identity_content = (new_dir / "identity.yml").read_text()
        assert 'name: "dev-1"' in identity_content


# ==================== create_agent project path warning ====================


class TestCreateAgentProjectPathWarning:
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value=None)
    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    def test_nonexistent_project_path_warning(self, mock_tmux, mock_run, mock_wf, capsys):
        """Pass project_path that doesn't exist, prints warning (line 583)."""
        mock_run.return_value = MagicMock(returncode=1)  # no session

        mgr = AgentManager()
        mgr.create_agent(
            session="sess",
            role="developer",
            project_path="/tmp/nonexistent_yato_test_path_xyz_999",
            start_claude=False,
            send_brief=False,
        )
        captured = capsys.readouterr()
        assert "Warning:" in captured.out
        assert "nonexistent_yato_test_path_xyz_999" in captured.out


# ==================== create_agent identity update ====================


class TestCreateAgentIdentityUpdate:
    @patch("lib.agent_manager.time.sleep")
    @patch("lib.agent_manager.send_message")
    @patch("lib.agent_manager.subprocess.run")
    @patch("lib.agent_manager._tmux_cmd", return_value=["tmux"])
    @patch("lib.agent_manager.WorkflowOps.get_current_workflow", return_value="001-test-feature")
    @patch("lib.agent_manager.WorkflowOps.add_agent_to_yml")
    def test_existing_identity_updated_with_pane_id(
        self, mock_add, mock_wf, mock_tmux, mock_run, mock_send, mock_sleep, tmp_workflow
    ):
        """When agent files already exist and session is active, identity.yml gets
        updated with pane_id and window info (lines 647-653)."""
        project = tmp_workflow.parent.parent

        # Pre-create agent directory with identity.yml (simulating files already exist)
        agent_dir = tmp_workflow / "agents" / "developer"
        agent_dir.mkdir(parents=True, exist_ok=True)
        (agent_dir / "identity.yml").write_text(
            "name: developer\nrole: developer\npane_id: \"\"\nwindow: 0\nsession: sess\n"
        )

        # has-session succeeds, new-window succeeds
        mock_run.side_effect = [
            MagicMock(returncode=0),           # has-session
            MagicMock(returncode=0, stdout="3:%42"),  # new-window
            MagicMock(returncode=0),           # send-keys (claude start)
        ]

        mgr = AgentManager()
        result = mgr.create_agent(
            session="sess",
            role="developer",
            project_path=str(project),
            model="sonnet",
        )

        assert result is not None
        assert result["pane_id"] == "%42"

        # Verify identity.yml was updated with new pane_id and window
        content = (agent_dir / "identity.yml").read_text()
        assert '"%42"' in content
        assert "window: 3" in content


# ==================== __main__ CLI ====================


class TestAgentManagerCLI:
    """Test the __main__ CLI block by exec'ing only the if-block with mocked objects."""

    @staticmethod
    def _exec_main_block(argv_args, mock_overrides=None):
        """Execute just the __main__ block of agent_manager.py.

        Extracts the if __name__ == "__main__" block from the source file,
        compiles it with the original filename and correct line offsets
        so coverage.py tracks the lines accurately.
        """
        import ast
        import lib.agent_manager as mod
        source_path = Path(mod.__file__).resolve()
        source = source_path.read_text()
        source_lines = source.splitlines(keepends=True)

        # Find the __main__ block start line (0-indexed)
        main_start = None
        for i, line in enumerate(source_lines):
            if line.strip().startswith("if __name__") and "__main__" in line:
                main_start = i
                break

        assert main_start is not None, "Could not find __main__ block"

        # Extract the block body (dedented by one level)
        block_lines = source_lines[main_start + 1:]
        dedented = []
        for line in block_lines:
            if line.strip() == "":
                dedented.append("\n")
            elif line.startswith("    "):
                dedented.append(line[4:])
            else:
                break
        block_source = "".join(dedented)

        # Parse, fix line numbers to match original file, compile
        tree = ast.parse(block_source, filename=str(source_path), mode="exec")
        ast.increment_lineno(tree, main_start + 1)  # +1 for the body starting after the if line
        code = compile(tree, str(source_path), "exec")

        # Build namespace
        ns = {"__builtins__": __builtins__}
        ns["AgentManager"] = AgentManager
        ns["create_agent"] = create_agent
        if mock_overrides:
            ns.update(mock_overrides)

        old_argv = sys.argv[:]
        try:
            sys.argv = ["lib.agent_manager"] + argv_args
            exec(code, ns)
        finally:
            sys.argv = old_argv

    def test_init_files_command(self, tmp_path):
        """Run with init-files subcommand (lines 840-867)."""
        mock_init = MagicMock(return_value=str(tmp_path / "agent"))
        MockAgent = type("AgentManager", (), {
            "init_agent_files": mock_init,
        })
        self._exec_main_block(
            ["init-files", "mydev", "developer", "-p", str(tmp_path)],
            mock_overrides={"AgentManager": MockAgent},
        )
        mock_init.assert_called_once_with(str(tmp_path), "mydev", "developer", "sonnet", None, is_existing_project=False)

    def test_create_command(self, tmp_path):
        """Run with create subcommand (lines 869-880)."""
        mock_create = MagicMock(return_value={"name": "dev", "role": "developer"})
        mock_model = MagicMock(return_value="sonnet")
        MockAgent = type("AgentManager", (), {
            "_get_default_model": mock_model,
        })
        self._exec_main_block(
            ["create", "mysession", "developer", "-p", str(tmp_path), "--no-start", "--no-brief"],
            mock_overrides={
                "create_agent": mock_create,
                "AgentManager": MockAgent,
            },
        )
        mock_create.assert_called_once_with(
            session="mysession", role="developer",
            project_path=str(tmp_path), name=None,
            model="sonnet", start_claude=False, send_brief=False,
        )

    def test_no_command_prints_help(self, capsys):
        """Run with no subcommand prints help (line 882-883)."""
        self._exec_main_block([])
        captured = capsys.readouterr()
        assert "usage:" in captured.out.lower() or "commands" in captured.out.lower()
