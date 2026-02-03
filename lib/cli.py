#!/usr/bin/env python3
"""
Yato CLI - Unified command-line interface for Yato orchestrator.

This module provides a single entry point for all Yato operations,
replacing the individual bash scripts in bin/.

Usage:
    uv run yato <command> [options]
    uv run python -m lib.cli <command> [options]

Commands:
    send        Send message to agent
    notify      Notify PM
    checkin     Check-in management (schedule, cancel, list, display)
    tasks       Task management (assign, list, table, display)
    workflow    Workflow operations (list, current, create)
    agent       Agent management (init-files, create)
    status      Show system status
"""

import argparse
import json
import sys
from typing import Optional


def cmd_send(args: argparse.Namespace) -> int:
    """Send message to agent."""
    from lib.tmux_utils import send_message

    message = " ".join(args.message)
    success = send_message(args.target, message, enter=not args.no_enter)

    if success:
        print(f"Message sent to {args.target}: {message}")
        return 0
    else:
        print(f"Failed to send message to {args.target}")
        return 1


def cmd_notify(args: argparse.Namespace) -> int:
    """Notify PM."""
    from lib.tmux_utils import notify_pm, get_current_session

    message = " ".join(args.message)
    success = notify_pm(message, session=args.session)

    if success:
        session = args.session or get_current_session()
        print(f"Notification sent to PM ({session}:0.1): {message}")
        return 0
    else:
        print("Failed to notify PM")
        return 1


def cmd_checkin_schedule(args: argparse.Namespace) -> int:
    """Schedule a check-in."""
    from lib.checkin_scheduler import schedule_checkin

    result = schedule_checkin(
        args.minutes,
        args.note or "Standard check-in",
        args.target or "tmux-orc:0",
        args.workflow,
    )
    return 0 if result else 1


def cmd_checkin_cancel(args: argparse.Namespace) -> int:
    """Cancel check-ins."""
    from lib.checkin_scheduler import cancel_checkin

    count = cancel_checkin(args.workflow)
    return 0


def cmd_checkin_list(args: argparse.Namespace) -> int:
    """List check-ins."""
    from lib.checkin_scheduler import CheckinScheduler, get_workflow_from_tmux, find_project_root

    workflow_name = args.workflow or get_workflow_from_tmux()
    if not workflow_name:
        print("Error: No workflow specified")
        return 1

    project_root = find_project_root()
    if not project_root:
        print("Error: Could not find .workflow/ directory")
        return 1

    workflow_path = project_root / ".workflow" / workflow_name
    if not workflow_path.exists():
        print(f"Error: Workflow not found: {workflow_path}")
        return 1

    scheduler = CheckinScheduler(str(workflow_path))
    checkins = scheduler.list_checkins(args.status)

    for c in checkins:
        print(json.dumps(c, indent=2))

    return 0


def cmd_tasks_assign(args: argparse.Namespace) -> int:
    """Assign task to agent."""
    from lib.task_manager import assign_task

    success = assign_task(args.agent, args.task, args.project, args.workflow)
    return 0 if success else 1


def cmd_tasks_list(args: argparse.Namespace) -> int:
    """List tasks."""
    from lib.task_manager import TaskManager, find_tasks_file

    tasks_file = find_tasks_file(args.project)
    if not tasks_file:
        print("(no tasks file found)")
        return 0

    manager = TaskManager(str(tasks_file.parent))
    tasks = manager.get_tasks(args.status, args.agent)

    for task in tasks:
        print(json.dumps(task, indent=2))

    return 0


def cmd_tasks_table(args: argparse.Namespace) -> int:
    """Display tasks as table."""
    from lib.task_manager import TaskManager, find_tasks_file

    tasks_file = find_tasks_file(args.project)
    if not tasks_file:
        print("(no tasks file found)")
        return 0

    manager = TaskManager(str(tasks_file.parent))
    print(manager.display_tasks_table())
    return 0


def cmd_tasks_display(args: argparse.Namespace) -> int:
    """Run continuous task display loop."""
    from lib.task_manager import TaskManager, find_tasks_file

    tasks_file = find_tasks_file(args.project)
    if not tasks_file:
        print("(no tasks file found)")
        return 1

    manager = TaskManager(str(tasks_file.parent))
    try:
        manager.run_display_loop(args.interval)
    except KeyboardInterrupt:
        print("\nDisplay stopped.")

    return 0


def cmd_workflow_list(args: argparse.Namespace) -> int:
    """List workflows."""
    from lib.workflow_ops import list_workflows

    workflows = list_workflows(args.project)
    for wf in workflows:
        print(f"{wf['name']} [{wf['status']}]")
        if wf.get("title"):
            print(f"  {wf['title']}")

    return 0


def cmd_workflow_current(args: argparse.Namespace) -> int:
    """Get current workflow."""
    from lib.workflow_ops import get_current_workflow

    current = get_current_workflow(args.project)
    if current:
        print(current)
    else:
        print("(no current workflow)")

    return 0


def cmd_workflow_create(args: argparse.Namespace) -> int:
    """Create workflow folder."""
    from lib.workflow_ops import create_workflow_folder

    folder = create_workflow_folder(args.project, args.title, session=args.session)
    print(f"Created: {folder}")
    return 0


def cmd_agent_init_files(args: argparse.Namespace) -> int:
    """Create agent configuration files."""
    from lib.agent_manager import init_agent_files

    result = init_agent_files(args.project, args.name, args.role, args.model)
    return 0 if result else 1


def cmd_agent_create(args: argparse.Namespace) -> int:
    """Create agent with tmux window."""
    from lib.agent_manager import create_agent

    result = create_agent(
        session=args.session,
        role=args.role,
        project_path=args.project,
        name=args.name,
        model=args.model,
        pm_window=args.pm_window,
        start_claude=not args.no_start,
        send_brief=not args.no_brief,
    )
    return 0 if result else 1


def cmd_status(args: argparse.Namespace) -> int:
    """Show system status."""
    from lib.tmux_utils import TmuxOrchestrator

    orchestrator = TmuxOrchestrator()
    orchestrator.safety_mode = False

    if args.json:
        status = orchestrator.get_all_windows_status()
        print(json.dumps(status, indent=2))
    else:
        print(orchestrator.create_monitoring_snapshot())

    return 0


def cmd_restart_checkin_display(args: argparse.Namespace) -> int:
    """Restart check-in display."""
    from lib.tmux_utils import restart_checkin_display

    success = restart_checkin_display(target=args.target)
    return 0 if success else 1


# ==================== loop commands ====================


def cmd_loop_start(args: argparse.Namespace) -> int:
    """Start a new loop."""
    from lib.loop_manager import start_loop, format_duration, parse_time_string

    # Get session_id - this should be provided or we need to get it somehow
    session_id = args.session
    if not session_id:
        print("Error: --session is required to identify the Claude session")
        print("You can find it in the hook input or pass it explicitly")
        return 1

    try:
        loop_id, folder = start_loop(
            prompt=args.prompt,
            session_id=session_id,
            interval=args.every,
            times=args.times,
            duration=getattr(args, 'for', None) or args.duration,
            project_path=args.project,
        )

        print(f"Loop started: {loop_id}")
        print(f"Folder: {folder}")

        interval_seconds = parse_time_string(args.every) if args.every else 0
        if interval_seconds > 0:
            print(f"Interval: {format_duration(interval_seconds)}")
        else:
            print("Interval: immediate (no delay)")

        if args.times:
            print(f"Will stop after: {args.times} executions")
        if getattr(args, 'for', None) or args.duration:
            dur = getattr(args, 'for', None) or args.duration
            print(f"Will stop after: {dur}")

        print("\nLoop is now active. The Stop hook will handle execution.")
        return 0

    except ValueError as e:
        print(f"Error: {e}")
        return 1


def cmd_loop_cancel(args: argparse.Namespace) -> int:
    """Cancel a loop."""
    from lib.loop_manager import cancel_loop, list_loops, LoopManager, find_project_root
    from pathlib import Path

    # If specific args provided, use them directly
    project_path = getattr(args, 'project', None)
    if args.session or args.loop_id or args.all:
        success = cancel_loop(
            session_id=args.session,
            loop_id=args.loop_id,
            project_path=project_path,
            cancel_all=args.all,
        )
        return 0 if success else 1

    # Otherwise, show list of running loops for user to choose
    running_loops = list_loops(status="running")

    if not running_loops:
        print("No running loops found.")
        return 0

    if len(running_loops) == 1:
        # Only one loop, cancel it directly
        loop = running_loops[0]
        project = find_project_root()
        manager = LoopManager(str(project))
        loop_folder = Path(loop["folder"])
        manager.stop_loop(loop_folder, "Cancelled by user")
        print(f"Cancelled loop: {loop['id']}")
        return 0

    # Multiple loops - show selection
    print("Running loops:\n")
    for i, loop in enumerate(running_loops, 1):
        prompt_preview = loop.get("prompt", "N/A")[:40]
        exec_count = loop.get("execution_count", 0)
        if loop.get("stop_after_times"):
            progress = f"{exec_count}/{loop['stop_after_times']}"
        else:
            progress = str(exec_count)
        print(f"  [{i}] {loop['id']}")
        print(f"      Prompt: {prompt_preview}...")
        print(f"      Progress: {progress} executions")
        print()

    print(f"  [a] Cancel ALL running loops")
    print()

    try:
        choice = input("Select loop to cancel (number or 'a' for all): ").strip().lower()

        if choice == 'a':
            success = cancel_loop(cancel_all=True)
            return 0 if success else 1

        idx = int(choice) - 1
        if 0 <= idx < len(running_loops):
            loop = running_loops[idx]
            project = find_project_root()
            manager = LoopManager(str(project))
            loop_folder = Path(loop["folder"])
            manager.stop_loop(loop_folder, "Cancelled by user")
            print(f"Cancelled loop: {loop['id']}")
            return 0
        else:
            print("Invalid selection")
            return 1

    except (ValueError, KeyboardInterrupt):
        print("\nCancelled")
        return 1


def cmd_loop_list(args: argparse.Namespace) -> int:
    """List loops."""
    from lib.loop_manager import list_loops, format_duration

    project_path = getattr(args, 'project', None)
    loops = list_loops(status=args.status, project_path=project_path)

    if not loops:
        print("No loops found")
        return 0

    for loop in loops:
        status_icon = "🟢" if loop["status"] == "running" else "⏹️"
        print(f"\n{status_icon} {loop['id']} [{loop['status']}]")
        print(f"   Prompt: {loop.get('prompt', 'N/A')[:50]}...")

        interval = loop.get("interval_seconds", 0)
        print(f"   Interval: {format_duration(interval) if interval > 0 else 'immediate'}")

        exec_count = loop.get("execution_count", 0)
        if loop.get("stop_after_times"):
            print(f"   Progress: {exec_count}/{loop['stop_after_times']} executions")
        elif loop.get("stop_after_seconds"):
            elapsed = loop.get("total_elapsed_seconds", 0)
            print(f"   Progress: {format_duration(elapsed)}/{format_duration(loop['stop_after_seconds'])}")
        else:
            print(f"   Executions: {exec_count}")

        print(f"   Session: {loop.get('session_id', 'N/A')}")

    return 0


def cmd_loop_status(args: argparse.Namespace) -> int:
    """Show status of a specific loop."""
    from lib.loop_manager import LoopManager, find_project_root
    from pathlib import Path

    project_path = getattr(args, 'project', None)
    project = Path(project_path) if project_path else find_project_root()
    manager = LoopManager(str(project))

    if args.session:
        loop_folder = manager.find_loop_by_session(args.session, only_running=False)
    elif args.loop_id:
        loop_folder = manager._get_loop_folder(args.loop_id)
    else:
        print("Specify --session or --loop-id")
        return 1

    if not loop_folder or not loop_folder.exists():
        print("Loop not found")
        return 1

    print(manager.get_loop_status_display(loop_folder))
    return 0


def main() -> int:
    """Main entry point."""
    parser = argparse.ArgumentParser(
        prog="yato",
        description="Yato - Yet Another Tmux Orchestrator",
    )
    parser.add_argument("--version", action="version", version="%(prog)s 1.1.0")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # ==================== send ====================
    send_parser = subparsers.add_parser("send", help="Send message to agent")
    send_parser.add_argument("target", help="Target (session:window or session:window.pane)")
    send_parser.add_argument("message", nargs="+", help="Message to send")
    send_parser.add_argument("--no-enter", action="store_true", help="Don't send Enter")
    send_parser.set_defaults(func=cmd_send)

    # ==================== notify ====================
    notify_parser = subparsers.add_parser("notify", help="Notify PM")
    notify_parser.add_argument("message", nargs="+", help="Message to send")
    notify_parser.add_argument("--session", "-s", help="Session name")
    notify_parser.set_defaults(func=cmd_notify)

    # ==================== checkin ====================
    checkin_parser = subparsers.add_parser("checkin", help="Check-in management")
    checkin_sub = checkin_parser.add_subparsers(dest="checkin_cmd")

    # checkin schedule
    checkin_schedule = checkin_sub.add_parser("schedule", help="Schedule check-in")
    checkin_schedule.add_argument("minutes", type=int, help="Minutes until check-in")
    checkin_schedule.add_argument("--note", "-n", help="Note for check-in")
    checkin_schedule.add_argument("--target", "-t", help="Target window")
    checkin_schedule.add_argument("--workflow", "-w", help="Workflow name")
    checkin_schedule.set_defaults(func=cmd_checkin_schedule)

    # checkin cancel
    checkin_cancel = checkin_sub.add_parser("cancel", help="Cancel check-ins")
    checkin_cancel.add_argument("--workflow", "-w", help="Workflow name")
    checkin_cancel.set_defaults(func=cmd_checkin_cancel)

    # checkin list
    checkin_list = checkin_sub.add_parser("list", help="List check-ins")
    checkin_list.add_argument("--status", "-s", help="Filter by status")
    checkin_list.add_argument("--workflow", "-w", help="Workflow name")
    checkin_list.set_defaults(func=cmd_checkin_list)

    # ==================== tasks ====================
    tasks_parser = subparsers.add_parser("tasks", help="Task management")
    tasks_sub = tasks_parser.add_subparsers(dest="tasks_cmd")

    # tasks assign
    tasks_assign = tasks_sub.add_parser("assign", help="Assign task to agent")
    tasks_assign.add_argument("agent", help="Agent name")
    tasks_assign.add_argument("task", help="Task description")
    tasks_assign.add_argument("--project", "-p", help="Project path")
    tasks_assign.add_argument("--workflow", "-w", help="Workflow name")
    tasks_assign.set_defaults(func=cmd_tasks_assign)

    # tasks list
    tasks_list = tasks_sub.add_parser("list", help="List tasks")
    tasks_list.add_argument("--status", "-s", help="Filter by status")
    tasks_list.add_argument("--agent", "-a", help="Filter by agent")
    tasks_list.add_argument("--project", "-p", help="Project path")
    tasks_list.set_defaults(func=cmd_tasks_list)

    # tasks table
    tasks_table = tasks_sub.add_parser("table", help="Display tasks as table")
    tasks_table.add_argument("--project", "-p", help="Project path")
    tasks_table.set_defaults(func=cmd_tasks_table)

    # tasks display
    tasks_display = tasks_sub.add_parser("display", help="Run continuous display")
    tasks_display.add_argument("--project", "-p", help="Project path")
    tasks_display.add_argument("--interval", "-i", type=int, default=3, help="Refresh interval")
    tasks_display.set_defaults(func=cmd_tasks_display)

    # ==================== workflow ====================
    workflow_parser = subparsers.add_parser("workflow", help="Workflow operations")
    workflow_sub = workflow_parser.add_subparsers(dest="workflow_cmd")

    # workflow list
    workflow_list = workflow_sub.add_parser("list", help="List workflows")
    workflow_list.add_argument("--project", "-p", default=".", help="Project path")
    workflow_list.set_defaults(func=cmd_workflow_list)

    # workflow current
    workflow_current = workflow_sub.add_parser("current", help="Get current workflow")
    workflow_current.add_argument("--project", "-p", default=".", help="Project path")
    workflow_current.set_defaults(func=cmd_workflow_current)

    # workflow create
    workflow_create = workflow_sub.add_parser("create", help="Create workflow folder")
    workflow_create.add_argument("title", help="Workflow title")
    workflow_create.add_argument("--project", "-p", default=".", help="Project path")
    workflow_create.add_argument("--session", "-s", default="", help="Tmux session name")
    workflow_create.set_defaults(func=cmd_workflow_create)

    # ==================== agent ====================
    agent_parser = subparsers.add_parser("agent", help="Agent management")
    agent_sub = agent_parser.add_subparsers(dest="agent_cmd")

    # agent init-files
    agent_init = agent_sub.add_parser("init-files", help="Create agent config files")
    agent_init.add_argument("name", help="Agent name")
    agent_init.add_argument("role", help="Agent role")
    agent_init.add_argument("--project", "-p", default=".", help="Project path")
    agent_init.add_argument("--model", "-m", default="sonnet", help="Model")
    agent_init.set_defaults(func=cmd_agent_init_files)

    # agent create
    agent_create = agent_sub.add_parser("create", help="Create agent with tmux window")
    agent_create.add_argument("session", help="Tmux session name")
    agent_create.add_argument("role", help="Agent role")
    agent_create.add_argument("--project", "-p", help="Project path")
    agent_create.add_argument("--name", "-n", help="Window name")
    agent_create.add_argument("--model", "-m", default="sonnet", help="Model")
    agent_create.add_argument("--pm-window", help="PM window (session:window)")
    agent_create.add_argument("--no-start", action="store_true", help="Don't start Claude")
    agent_create.add_argument("--no-brief", action="store_true", help="Don't send briefing")
    agent_create.set_defaults(func=cmd_agent_create)

    # ==================== status ====================
    status_parser = subparsers.add_parser("status", help="Show system status")
    status_parser.add_argument("--json", action="store_true", help="Output as JSON")
    status_parser.set_defaults(func=cmd_status)

    # ==================== restart-checkin-display ====================
    restart_parser = subparsers.add_parser("restart-checkin-display", help="Restart check-in display")
    restart_parser.add_argument("--target", "-t", help="Target window")
    restart_parser.set_defaults(func=cmd_restart_checkin_display)

    # ==================== loop ====================
    loop_parser = subparsers.add_parser("loop", help="Loop management (repeating prompts)")
    loop_sub = loop_parser.add_subparsers(dest="loop_cmd")

    # loop start
    loop_start = loop_sub.add_parser("start", help="Start a new loop")
    loop_start.add_argument("prompt", help="Prompt to repeat")
    loop_start.add_argument("--session", "-s", required=True, help="Claude session ID")
    loop_start.add_argument("--project", "-p", help="Project path (defaults to cwd)")
    loop_start.add_argument("--every", "-e", help="Interval (e.g., 5m, 30s, 1h). Optional, defaults to immediate.")
    loop_start.add_argument("--times", "-t", type=int, help="Stop after N executions")
    loop_start.add_argument("--for", "-f", "--duration", "-d", dest="duration", help="Stop after duration (e.g., 30m, 1h)")
    loop_start.set_defaults(func=cmd_loop_start)

    # loop cancel
    loop_cancel = loop_sub.add_parser("cancel", help="Cancel a loop")
    loop_cancel.add_argument("--session", "-s", help="Cancel loop for this session")
    loop_cancel.add_argument("--loop-id", "-l", help="Cancel specific loop by ID")
    loop_cancel.add_argument("--project", "-p", help="Project path (defaults to cwd)")
    loop_cancel.add_argument("--all", "-a", action="store_true", help="Cancel all running loops")
    loop_cancel.set_defaults(func=cmd_loop_cancel)

    # loop list
    loop_list = loop_sub.add_parser("list", help="List loops")
    loop_list.add_argument("--status", help="Filter by status (running, stopped)")
    loop_list.add_argument("--project", "-p", help="Project path (defaults to cwd)")
    loop_list.set_defaults(func=cmd_loop_list)

    # loop status
    loop_status = loop_sub.add_parser("status", help="Show loop status")
    loop_status.add_argument("--session", "-s", help="Session ID")
    loop_status.add_argument("--loop-id", "-l", help="Loop ID")
    loop_status.add_argument("--project", "-p", help="Project path (defaults to cwd)")
    loop_status.set_defaults(func=cmd_loop_status)

    # Parse and execute
    args = parser.parse_args()

    if args.command is None:
        parser.print_help()
        return 0

    # Check for subcommand if needed
    if args.command == "checkin" and not hasattr(args, "func"):
        checkin_parser.print_help()
        return 0
    if args.command == "tasks" and not hasattr(args, "func"):
        tasks_parser.print_help()
        return 0
    if args.command == "workflow" and not hasattr(args, "func"):
        workflow_parser.print_help()
        return 0
    if args.command == "agent" and not hasattr(args, "func"):
        agent_parser.print_help()
        return 0
    if args.command == "loop" and not hasattr(args, "func"):
        loop_parser.print_help()
        return 0

    return args.func(args)


if __name__ == "__main__":
    sys.exit(main())
