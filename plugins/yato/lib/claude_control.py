#!/usr/bin/env python3
"""
Claude Control CLI - Command-line interface for managing Claude agents.

This provides a unified interface for:
- Viewing agent status (workflow-scoped)
- Listing tmux sessions/windows
- Sending messages to agents
- Reading agent output
- Managing agents within workflows
"""

import argparse
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional, List

# Handle imports for both `uv run` and direct `python3 lib/claude_control.py` execution
try:
    from lib.session_registry import Agent
    from lib.workflow_registry import WorkflowRegistry
except ModuleNotFoundError:
    # Running as script, add parent directory to path
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from lib.session_registry import Agent
    from lib.workflow_registry import WorkflowRegistry


class TmuxController:
    """Interface for tmux operations."""

    @staticmethod
    def run_tmux(args: List[str], capture_output: bool = True) -> subprocess.CompletedProcess:
        """Run a tmux command."""
        socket = os.environ.get("TMUX_SOCKET")
        cmd = (["tmux", "-L", socket] if socket else ["tmux"]) + args
        return subprocess.run(cmd, capture_output=capture_output, text=True)

    @staticmethod
    def list_sessions() -> List[dict]:
        """List all tmux sessions."""
        result = TmuxController.run_tmux([
            "list-sessions",
            "-F", "#{session_name}:#{session_windows}:#{session_attached}"
        ])

        if result.returncode != 0:
            return []

        sessions = []
        for line in result.stdout.strip().split("\n"):
            if line:
                parts = line.split(":")
                if len(parts) >= 3:
                    sessions.append({
                        "name": parts[0],
                        "windows": int(parts[1]),
                        "attached": parts[2] == "1"
                    })
        return sessions

    @staticmethod
    def list_windows(session: str) -> List[dict]:
        """List all windows in a session."""
        result = TmuxController.run_tmux([
            "list-windows",
            "-t", session,
            "-F", "#{window_index}:#{window_name}:#{pane_current_path}"
        ])

        if result.returncode != 0:
            return []

        windows = []
        for line in result.stdout.strip().split("\n"):
            if line:
                parts = line.split(":")
                if len(parts) >= 3:
                    windows.append({
                        "index": int(parts[0]),
                        "name": parts[1],
                        "path": ":".join(parts[2:])  # Handle paths with colons
                    })
        return windows

    @staticmethod
    def capture_pane(target: str, lines: int = 100) -> str:
        """Capture output from a tmux pane."""
        result = TmuxController.run_tmux([
            "capture-pane",
            "-t", target,
            "-p",
            "-S", f"-{lines}"
        ])

        if result.returncode != 0:
            return f"Error capturing pane: {result.stderr}"

        return result.stdout

    @staticmethod
    def send_keys(target: str, message: str, send_enter: bool = True) -> bool:
        """Send keys to a tmux target.

        Uses bracketed paste (load-buffer + paste-buffer -p) for multi-line
        messages to preserve newlines. Single-line messages use send-keys -l.
        """
        import tempfile
        import time

        if "\n" in message:
            with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
                f.write(message)
                tmp_path = f.name
            try:
                buf_name = f"yato-cc-{os.getpid()}"
                result = TmuxController.run_tmux(["load-buffer", "-b", buf_name, tmp_path])
                if result.returncode != 0:
                    return False
                result = TmuxController.run_tmux(["paste-buffer", "-p", "-d", "-b", buf_name, "-t", target])
                if result.returncode != 0:
                    return False
            finally:
                os.unlink(tmp_path)
        else:
            result = TmuxController.run_tmux(["send-keys", "-l", "-t", target, message])
            if result.returncode != 0:
                return False

        if send_enter:
            time.sleep(0.5)
            result = TmuxController.run_tmux(["send-keys", "-t", target, "Enter"])

        return result.returncode == 0

    @staticmethod
    def create_window(session: str, name: str, path: Optional[str] = None) -> Optional[int]:
        """Create a new window in a session."""
        args = ["new-window", "-d", "-t", session, "-n", name, "-P", "-F", "#{window_index}"]
        if path:
            args.extend(["-c", path])

        result = TmuxController.run_tmux(args)
        if result.returncode != 0:
            return None

        try:
            return int(result.stdout.strip())
        except ValueError:
            return None

    @staticmethod
    def session_exists(session: str) -> bool:
        """Check if a session exists."""
        result = TmuxController.run_tmux(["has-session", "-t", session])
        return result.returncode == 0


class ClaudeControl:
    """Main CLI controller for Claude agents."""

    def __init__(self, project_path: Optional[str] = None, workflow_name: Optional[str] = None):
        """
        Initialize controller.

        Args:
            project_path: Path to project (for workflow-scoped operations)
            workflow_name: Specific workflow name (optional, auto-detected if not provided)
        """
        self.tmux = TmuxController()
        self.project_path = Path(project_path).expanduser().resolve() if project_path else None
        self.workflow_name = workflow_name
        self._registry = None

    @property
    def registry(self) -> Optional[WorkflowRegistry]:
        """Get workflow registry (lazy-loaded)."""
        if self._registry is None and self.project_path:
            self._registry = WorkflowRegistry.from_project(self.project_path, self.workflow_name)
        return self._registry

    def cmd_status(self, args: argparse.Namespace) -> int:
        """Show status of all registered agents in the current workflow."""
        if not self.registry:
            print("No workflow found. Use --project-path to specify a project.")
            print("Or run from a project directory with a .workflow folder.")
            return 0

        agents = self.registry.list_agents()

        if not agents:
            print("No registered agents in this workflow.")
            return 0

        workflow_name = self.registry.workflow_path.name
        print(f"\nWorkflow: {workflow_name}")
        print(f"{'='*60}")
        print(f"{'NAME':<20} {'ROLE':<12} {'TARGET':<20} {'MODEL'}")
        print(f"{'='*60}")

        for agent in agents:
            name = agent.name or agent.role
            target = agent.target
            model = agent.model or "sonnet"
            print(f"{name:<20} {agent.role:<12} {target:<20} {model}")

        print(f"{'='*60}")
        print(f"Total: {len(agents)} agent(s)\n")

        return 0

    def cmd_list(self, args: argparse.Namespace) -> int:
        """List tmux sessions and windows."""
        sessions = self.tmux.list_sessions()

        if not sessions:
            print("No tmux sessions found.")
            return 0

        print(f"\n{'='*70}")
        for session in sessions:
            attached = " (attached)" if session["attached"] else ""
            print(f"\nSession: {session['name']}{attached}")
            print(f"{'-'*70}")

            windows = self.tmux.list_windows(session["name"])
            for window in windows:
                target = f"{session['name']}:{window['index']}"

                # Try to find agent in registry if available
                agent_info = ""
                if self.registry:
                    agent = self.registry.get_agent_by_target(session["name"], window["index"])
                    if agent:
                        agent_info = f" [{agent.role}]"

                print(f"  {window['index']}: {window['name']}{agent_info}")
                if args.verbose:
                    print(f"      Path: {window['path']}")

        print(f"\n{'='*70}\n")
        return 0

    def cmd_send(self, args: argparse.Namespace) -> int:
        """Send a message to an agent."""
        target = args.target
        message = args.message

        # Verify target exists
        if ":" not in target:
            print(f"Error: Invalid target format. Use 'session:window'")
            return 1

        session = target.split(":")[0]
        if not self.tmux.session_exists(session):
            print(f"Error: Session '{session}' does not exist")
            return 1

        if self.tmux.send_keys(target, message):
            print(f"Message sent to {target}")
            return 0
        else:
            print(f"Error: Failed to send message to {target}")
            return 1

    def cmd_read(self, args: argparse.Namespace) -> int:
        """Read output from an agent window."""
        target = args.target
        lines = args.lines

        output = self.tmux.capture_pane(target, lines)
        print(output)

        return 0

    def cmd_register(self, args: argparse.Namespace) -> int:
        """Register an existing window or pane as an agent."""
        if not self.registry:
            print("Error: No workflow found. Use --project-path to specify a project.")
            return 1

        target = args.target
        role = args.role
        name = args.name or role.title()
        model = args.model or "sonnet"

        if ":" not in target:
            print(f"Error: Invalid target format. Use 'session:window' or 'session:window.pane'")
            return 1

        parts = target.split(":")
        session = parts[0]
        window_part = parts[1]

        # Check if pane is included (e.g., "0.1")
        if "." in window_part:
            window_str, pane_str = window_part.split(".", 1)
            try:
                window = int(window_str)
            except ValueError:
                print(f"Error: Window must be a number")
                return 1
        else:
            try:
                window = int(window_part)
            except ValueError:
                print(f"Error: Window must be a number")
                return 1

        agent = Agent(
            session_name=session,
            window_index=window,
            role=role,
            name=name,
            model=model,
        )
        self.registry.add_agent(agent)

        print(f"Registered agent: {agent.agent_id} as {role}")
        return 0

    def cmd_unregister(self, args: argparse.Namespace) -> int:
        """Unregister an agent."""
        if not self.registry:
            print("Error: No workflow found. Use --project-path to specify a project.")
            return 1

        name = args.name

        if self.registry.remove_agent(name):
            print(f"Unregistered agent: {name}")
            return 0
        else:
            print(f"Agent not found: {name}")
            return 1

    def cmd_team(self, args: argparse.Namespace) -> int:
        """Show team for a PM."""
        if not self.registry:
            print("Error: No workflow found. Use --project-path to specify a project.")
            return 1

        pm = self.registry.get_pm()
        if not pm:
            print("No PM found in this workflow")
            return 1

        team = self.registry.get_team()

        print(f"\nWorkflow: {self.registry.workflow_path.name}")
        print(f"PM: {pm.name or 'PM'} at {pm.target}")
        print(f"{'-'*50}")

        if not team:
            print("  No team members registered")
        else:
            for agent in team:
                name = agent.name or agent.role
                print(f"  {name}: {agent.role} at {agent.target} ({agent.model or 'sonnet'})")

        print()
        return 0


def main():
    parser = argparse.ArgumentParser(
        description="Claude Control - Manage Claude AI agents in tmux",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    # Global options for workflow context
    parser.add_argument("-p", "--project-path", help="Project path for workflow-scoped operations")
    parser.add_argument("-w", "--workflow", help="Specific workflow name (auto-detected if not provided)")

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # status command
    status_parser = subparsers.add_parser("status", help="Show all registered agents in workflow")

    # list command
    list_parser = subparsers.add_parser("list", help="List tmux sessions and windows")
    list_parser.add_argument("-v", "--verbose", action="store_true", help="Show detailed info")

    # send command
    send_parser = subparsers.add_parser("send", help="Send message to an agent")
    send_parser.add_argument("target", help="Target (session:window)")
    send_parser.add_argument("message", help="Message to send")

    # read command
    read_parser = subparsers.add_parser("read", help="Read output from agent window")
    read_parser.add_argument("target", help="Target (session:window)")
    read_parser.add_argument("-n", "--lines", type=int, default=50, help="Number of lines to capture")

    # register command
    register_parser = subparsers.add_parser("register", help="Register existing window as agent")
    register_parser.add_argument("target", help="Target (session:window)")
    register_parser.add_argument("role", help="Agent role")
    register_parser.add_argument("-n", "--name", help="Agent name (default: role)")
    register_parser.add_argument("-m", "--model", help="Claude model (opus, sonnet, haiku)")

    # unregister command
    unregister_parser = subparsers.add_parser("unregister", help="Unregister an agent")
    unregister_parser.add_argument("name", help="Agent name")

    # team command
    team_parser = subparsers.add_parser("team", help="Show team for workflow")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 0

    # Determine project path
    project_path = args.project_path
    if not project_path:
        # Try current directory
        cwd = Path.cwd()
        if (cwd / ".workflow").exists():
            project_path = str(cwd)

    controller = ClaudeControl(project_path=project_path, workflow_name=args.workflow)

    # Dispatch to command handler
    cmd_map = {
        "status": controller.cmd_status,
        "list": controller.cmd_list,
        "send": controller.cmd_send,
        "read": controller.cmd_read,
        "register": controller.cmd_register,
        "unregister": controller.cmd_unregister,
        "team": controller.cmd_team,
    }

    handler = cmd_map.get(args.command)
    if handler:
        return handler(args)
    else:
        print(f"Unknown command: {args.command}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
