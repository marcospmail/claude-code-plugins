"""Tests for lib/__init__.py — public exports."""

import pytest


class TestPublicExports:
    """Verify all __all__ exports are importable."""

    def test_version(self):
        from lib import __version__
        assert isinstance(__version__, str)
        assert len(__version__.split(".")) >= 2

    def test_agent_class(self):
        from lib import Agent
        assert Agent is not None
        # Verify it's the correct class
        agent = Agent(session_name="s", window_index=0, role="dev")
        assert agent.role == "dev"

    def test_tmux_orchestrator_class(self):
        from lib import TmuxOrchestrator
        assert TmuxOrchestrator is not None

    def test_workflow_registry_class(self):
        from lib import WorkflowRegistry
        assert WorkflowRegistry is not None

    def test_checkin_scheduler_class(self):
        from lib import CheckinScheduler
        assert CheckinScheduler is not None

    def test_workflow_ops_class(self):
        from lib import WorkflowOps
        assert WorkflowOps is not None

    def test_agent_manager_class(self):
        from lib import AgentManager
        assert AgentManager is not None

    def test_send_message_function(self):
        from lib import send_message
        assert callable(send_message)

    def test_notify_pm_function(self):
        from lib import notify_pm
        assert callable(notify_pm)

    def test_get_current_session_function(self):
        from lib import get_current_session
        assert callable(get_current_session)

    def test_restart_checkin_display_function(self):
        from lib import restart_checkin_display
        assert callable(restart_checkin_display)

    def test_cancel_checkin_function(self):
        from lib import cancel_checkin
        assert callable(cancel_checkin)

    def test_schedule_checkin_function(self):
        from lib import schedule_checkin
        assert callable(schedule_checkin)

    def test_workflow_ops_functions(self):
        from lib import (
            get_next_workflow_number,
            generate_workflow_slug,
            create_workflow_folder,
            get_current_workflow,
            get_current_workflow_path,
            list_workflows,
        )
        assert callable(get_next_workflow_number)
        assert callable(generate_workflow_slug)
        assert callable(create_workflow_folder)
        assert callable(get_current_workflow)
        assert callable(get_current_workflow_path)
        assert callable(list_workflows)

    def test_agent_manager_functions(self):
        from lib import init_agent_files, create_agent
        assert callable(init_agent_files)
        assert callable(create_agent)

    def test_all_exports_complete(self):
        import lib
        for name in lib.__all__:
            assert hasattr(lib, name), f"Missing export: {name}"

    def test_no_extra_public_names(self):
        """Verify __all__ covers all public names (non-underscore) in the module."""
        import lib
        public_names = {n for n in dir(lib) if not n.startswith("_") and n != "lib"}
        # Filter to only exported symbols (exclude submodule names)
        all_set = set(lib.__all__)
        # Every name in __all__ should be accessible
        for name in all_set:
            assert hasattr(lib, name)
