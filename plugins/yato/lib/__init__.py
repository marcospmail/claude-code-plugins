"""
Yato - Yet Another Tmux Orchestrator

A Claude Code plugin for multi-agent coordination across tmux sessions.
"""

__version__ = "3.15.0"

# Core classes
from lib.session_registry import Agent
from lib.tmux_utils import (
    TmuxOrchestrator,
    send_message,
    notify_pm,
    get_current_session,
    restart_checkin_display,
)
from lib.workflow_registry import WorkflowRegistry
from lib.checkin_scheduler import CheckinScheduler, cancel_checkin, schedule_checkin
from lib.workflow_ops import (
    WorkflowOps,
    get_next_workflow_number,
    generate_workflow_slug,
    create_workflow_folder,
    get_current_workflow,
    get_current_workflow_path,
    list_workflows,
)
from lib.agent_manager import AgentManager, init_agent_files, create_agent

__all__ = [
    "Agent",
    "TmuxOrchestrator",
    "WorkflowRegistry",
    "CheckinScheduler",
    "WorkflowOps",
    "AgentManager",
    "send_message",
    "notify_pm",
    "get_current_session",
    "restart_checkin_display",
    "cancel_checkin",
    "schedule_checkin",
    "get_next_workflow_number",
    "generate_workflow_slug",
    "create_workflow_folder",
    "get_current_workflow",
    "get_current_workflow_path",
    "list_workflows",
    "init_agent_files",
    "create_agent",
    "__version__",
]
