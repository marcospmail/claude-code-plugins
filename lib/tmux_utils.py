#!/usr/bin/env python3
"""
Tmux Utilities - Python utilities for tmux operations.

This module provides a comprehensive interface for:
- Managing tmux sessions and windows
- Capturing and analyzing window content
- Sending messages to agents
- Integration with the session registry
"""

import subprocess
import json
import time
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

# Import session registry
from session_registry import SessionRegistry, Agent


@dataclass
class TmuxWindow:
    """Represents a tmux window."""
    session_name: str
    window_index: int
    window_name: str
    active: bool


@dataclass
class TmuxSession:
    """Represents a tmux session."""
    name: str
    windows: List[TmuxWindow]
    attached: bool


class TmuxOrchestrator:
    """
    Main class for tmux orchestration operations.

    Provides methods for:
    - Session/window management
    - Content capture and analysis
    - Message sending to agents
    - Registry integration
    """

    def __init__(self, registry_path: Optional[Path] = None):
        self.safety_mode = True
        self.max_lines_capture = 1000
        self.message_delay = 0.5  # Delay between message and Enter
        self.registry = SessionRegistry(registry_path)

    # ==================== Session/Window Management ====================

    def get_tmux_sessions(self) -> List[TmuxSession]:
        """Get all tmux sessions and their windows."""
        try:
            sessions_cmd = ["tmux", "list-sessions", "-F", "#{session_name}:#{session_attached}"]
            sessions_result = subprocess.run(sessions_cmd, capture_output=True, text=True, check=True)

            sessions = []
            for line in sessions_result.stdout.strip().split('\n'):
                if not line:
                    continue
                session_name, attached = line.split(':')

                # Get windows for this session
                windows_cmd = ["tmux", "list-windows", "-t", session_name, "-F", "#{window_index}:#{window_name}:#{window_active}"]
                windows_result = subprocess.run(windows_cmd, capture_output=True, text=True, check=True)

                windows = []
                for window_line in windows_result.stdout.strip().split('\n'):
                    if not window_line:
                        continue
                    window_index, window_name, window_active = window_line.split(':')
                    windows.append(TmuxWindow(
                        session_name=session_name,
                        window_index=int(window_index),
                        window_name=window_name,
                        active=window_active == '1'
                    ))

                sessions.append(TmuxSession(
                    name=session_name,
                    windows=windows,
                    attached=attached == '1'
                ))

            return sessions
        except subprocess.CalledProcessError as e:
            print(f"Error getting tmux sessions: {e}")
            return []

    def session_exists(self, session_name: str) -> bool:
        """Check if a tmux session exists."""
        result = subprocess.run(
            ["tmux", "has-session", "-t", session_name],
            capture_output=True
        )
        return result.returncode == 0

    def create_session(self, name: str, path: Optional[str] = None) -> bool:
        """Create a new tmux session."""
        cmd = ["tmux", "new-session", "-d", "-s", name]
        if path:
            cmd.extend(["-c", path])

        result = subprocess.run(cmd, capture_output=True)
        return result.returncode == 0

    def create_window(self, session: str, name: str, path: Optional[str] = None) -> Optional[int]:
        """Create a new window in a session, returning the window index."""
        cmd = ["tmux", "new-window", "-t", session, "-n", name, "-P", "-F", "#{window_index}"]
        if path:
            cmd.extend(["-c", path])

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return None

        try:
            return int(result.stdout.strip())
        except ValueError:
            return None

    def create_pane(self, target: str, path: Optional[str] = None, vertical: bool = True) -> Optional[str]:
        """
        Create a new pane by splitting an existing pane.

        Args:
            target: Target pane to split (e.g., "session:0.0")
            path: Working directory for the new pane
            vertical: If True, split vertically (-v), else horizontally (-h)

        Returns:
            The new pane ID (e.g., "session:0.1") or None on failure
        """
        split_flag = "-v" if vertical else "-h"
        cmd = ["tmux", "split-window", split_flag, "-t", target, "-P", "-F", "#{session_name}:#{window_index}.#{pane_index}"]
        if path:
            cmd.extend(["-c", path])

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return None

        return result.stdout.strip()

    def set_pane_title(self, target: str, title: str) -> bool:
        """Set a title for a pane (requires pane-border-format to show)."""
        # Select the pane and set its title
        cmd = ["tmux", "select-pane", "-t", target, "-T", title]
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.returncode == 0

    def tile_panes(self, target: str) -> bool:
        """Arrange all panes in a window in a tiled layout."""
        # Get the window part of target (session:window)
        window_target = target.rsplit(".", 1)[0] if "." in target else target
        cmd = ["tmux", "select-layout", "-t", window_target, "tiled"]
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.returncode == 0

    # ==================== Content Capture ====================

    def capture_window_content(self, session_name: str, window_index: int, num_lines: int = 50) -> str:
        """Safely capture the last N lines from a tmux window."""
        if num_lines > self.max_lines_capture:
            num_lines = self.max_lines_capture

        try:
            cmd = ["tmux", "capture-pane", "-t", f"{session_name}:{window_index}", "-p", "-S", f"-{num_lines}"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout
        except subprocess.CalledProcessError as e:
            return f"Error capturing window content: {e}"

    def capture_agent_output(self, agent_id: str, num_lines: int = 50) -> str:
        """Capture output from a registered agent.

        Supports both window format (session:window) and pane format (session:window.pane).
        """
        if ":" not in agent_id:
            return f"Invalid agent_id format: {agent_id}"

        session, target = agent_id.split(":", 1)

        # Check if target includes a pane (e.g., "0.1")
        if "." in target:
            return self._capture_pane_content(agent_id, num_lines)

        try:
            return self.capture_window_content(session, int(target), num_lines)
        except ValueError:
            return f"Invalid window index in agent_id: {agent_id}"

    def _capture_pane_content(self, target: str, num_lines: int = 50) -> str:
        """Capture content from a specific pane target (session:window.pane)."""
        if num_lines > self.max_lines_capture:
            num_lines = self.max_lines_capture

        try:
            cmd = ["tmux", "capture-pane", "-t", target, "-p", "-S", f"-{num_lines}"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout
        except subprocess.CalledProcessError as e:
            return f"Error capturing pane content: {e}"

    def get_window_info(self, session_name: str, window_index: int) -> Dict:
        """Get detailed information about a specific window."""
        try:
            cmd = ["tmux", "display-message", "-t", f"{session_name}:{window_index}", "-p",
                   "#{window_name}:#{window_active}:#{window_panes}:#{pane_current_path}"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)

            if result.stdout.strip():
                parts = result.stdout.strip().split(':')
                return {
                    "name": parts[0],
                    "active": parts[1] == '1',
                    "panes": int(parts[2]),
                    "path": ":".join(parts[3:]) if len(parts) > 3 else "",
                    "content": self.capture_window_content(session_name, window_index)
                }
        except subprocess.CalledProcessError as e:
            return {"error": f"Could not get window info: {e}"}
        return {}

    # ==================== Message Sending ====================

    def send_keys_to_window(self, session_name: str, window_index: int, keys: str, confirm: bool = True) -> bool:
        """Safely send keys to a tmux window with confirmation."""
        if self.safety_mode and confirm:
            print(f"SAFETY CHECK: About to send '{keys}' to {session_name}:{window_index}")
            response = input("Confirm? (yes/no): ")
            if response.lower() != 'yes':
                print("Operation cancelled")
                return False

        try:
            cmd = ["tmux", "send-keys", "-t", f"{session_name}:{window_index}", keys]
            subprocess.run(cmd, check=True)
            return True
        except subprocess.CalledProcessError as e:
            print(f"Error sending keys: {e}")
            return False

    def send_command_to_window(self, session_name: str, window_index: int, command: str, confirm: bool = True) -> bool:
        """Send a command to a window (adds Enter automatically with proper delay)."""
        # First send the command text
        if not self.send_keys_to_window(session_name, window_index, command, confirm):
            return False

        # Wait before sending Enter
        time.sleep(self.message_delay)

        # Then send the actual Enter key
        try:
            cmd = ["tmux", "send-keys", "-t", f"{session_name}:{window_index}", "Enter"]
            subprocess.run(cmd, check=True)
            return True
        except subprocess.CalledProcessError as e:
            print(f"Error sending Enter key: {e}")
            return False

    def send_message_to_agent(self, agent_id: str, message: str, confirm: bool = False) -> bool:
        """Send a message to a registered agent.

        Supports both window format (session:window) and pane format (session:window.pane).
        """
        if ":" not in agent_id:
            print(f"Invalid agent_id format: {agent_id}")
            return False

        session, target = agent_id.split(":", 1)

        # Check if target includes a pane (e.g., "0.1")
        if "." in target:
            # Use tmux send-keys directly with the full target
            return self._send_to_pane(agent_id, message, confirm)

        try:
            window_idx = int(target)
        except ValueError:
            print(f"Invalid window index in agent_id: {agent_id}")
            return False

        return self.send_command_to_window(session, window_idx, message, confirm)

    def _send_to_pane(self, target: str, message: str, confirm: bool = False) -> bool:
        """Send a message to a specific pane target (session:window.pane)."""
        if self.safety_mode and confirm:
            print(f"SAFETY CHECK: About to send '{message}' to {target}")
            response = input("Confirm? (yes/no): ")
            if response.lower() != 'yes':
                print("Operation cancelled")
                return False

        try:
            # Send the message text
            cmd = ["tmux", "send-keys", "-t", target, message]
            subprocess.run(cmd, check=True)

            # Wait before sending Enter
            time.sleep(self.message_delay)

            # Send Enter
            cmd = ["tmux", "send-keys", "-t", target, "Enter"]
            subprocess.run(cmd, check=True)
            return True
        except subprocess.CalledProcessError as e:
            print(f"Error sending to pane: {e}")
            return False

    # ==================== Agent Registry Integration ====================

    def register_agent(
        self,
        session_name: str,
        window_index: int,
        role: str,
        pm_window: Optional[str] = None,
        project_path: Optional[str] = None,
        name: Optional[str] = None,
        focus: Optional[str] = None,
        skills: Optional[List[str]] = None,
        briefing: Optional[str] = None,
        model: Optional[str] = None,
        pane_index: Optional[int] = None
    ) -> Agent:
        """Register a new agent in the registry."""
        return self.registry.register_agent(
            session_name=session_name,
            window_index=window_index,
            role=role,
            pm_window=pm_window,
            project_path=project_path,
            name=name,
            focus=focus,
            skills=skills,
            briefing=briefing,
            model=model,
            pane_index=pane_index
        )

    def unregister_agent(self, agent_id: str) -> bool:
        """Remove an agent from the registry."""
        return self.registry.unregister_agent(agent_id)

    def get_agent(self, agent_id: str) -> Optional[Agent]:
        """Get an agent by ID."""
        return self.registry.get_agent(agent_id)

    def list_agents(self, role: Optional[str] = None, session: Optional[str] = None) -> List[Agent]:
        """List all registered agents."""
        return self.registry.list_agents(role=role, session=session)

    def get_pm_for_agent(self, agent_id: str) -> Optional[Agent]:
        """Get the PM for a given agent."""
        return self.registry.get_pm_for_agent(agent_id)

    def get_team_for_pm(self, pm_id: str) -> List[Agent]:
        """Get all agents reporting to a PM."""
        return self.registry.get_team_for_pm(pm_id)

    def get_agents_with_status(self) -> List[Dict]:
        """Get all agents with their current window status."""
        agents = self.registry.list_agents()
        result = []

        for agent in agents:
            window_info = self.get_window_info(agent.session_name, agent.window_index)
            result.append({
                "agent": agent.to_dict(),
                "window_info": window_info
            })

        return result

    # ==================== Status and Monitoring ====================

    def get_all_windows_status(self) -> Dict:
        """Get status of all windows across all sessions."""
        sessions = self.get_tmux_sessions()
        status = {
            "timestamp": datetime.now().isoformat(),
            "sessions": []
        }

        for session in sessions:
            session_data = {
                "name": session.name,
                "attached": session.attached,
                "windows": []
            }

            for window in session.windows:
                window_info = self.get_window_info(session.name, window.window_index)

                # Check if this window has a registered agent
                agent = self.registry.get_agent(f"{session.name}:{window.window_index}")

                window_data = {
                    "index": window.window_index,
                    "name": window.window_name,
                    "active": window.active,
                    "info": window_info,
                    "agent": agent.to_dict() if agent else None
                }
                session_data["windows"].append(window_data)

            status["sessions"].append(session_data)

        return status

    def find_window_by_name(self, window_name: str) -> List[Tuple[str, int]]:
        """Find windows by name across all sessions."""
        sessions = self.get_tmux_sessions()
        matches = []

        for session in sessions:
            for window in session.windows:
                if window_name.lower() in window.window_name.lower():
                    matches.append((session.name, window.window_index))

        return matches

    def create_monitoring_snapshot(self) -> str:
        """Create a comprehensive snapshot for Claude analysis."""
        status = self.get_all_windows_status()

        # Format for Claude consumption
        snapshot = f"Tmux Monitoring Snapshot - {status['timestamp']}\n"
        snapshot += "=" * 60 + "\n\n"

        for session in status['sessions']:
            snapshot += f"Session: {session['name']} ({'ATTACHED' if session['attached'] else 'DETACHED'})\n"
            snapshot += "-" * 40 + "\n"

            for window in session['windows']:
                snapshot += f"  Window {window['index']}: {window['name']}"
                if window['active']:
                    snapshot += " (ACTIVE)"

                # Show agent info if registered
                if window['agent']:
                    snapshot += f" [{window['agent']['role']}]"

                snapshot += "\n"

                if 'content' in window['info']:
                    # Get last 10 lines for overview
                    content_lines = window['info']['content'].split('\n')
                    recent_lines = content_lines[-10:] if len(content_lines) > 10 else content_lines
                    snapshot += "    Recent output:\n"
                    for line in recent_lines:
                        if line.strip():
                            snapshot += f"    | {line}\n"
                snapshot += "\n"

        # Add registered agents summary
        agents = self.registry.list_agents()
        if agents:
            snapshot += "\n" + "=" * 60 + "\n"
            snapshot += "Registered Agents\n"
            snapshot += "-" * 40 + "\n"
            for agent in agents:
                pm_info = f" → {agent.pm_window}" if agent.pm_window else ""
                snapshot += f"  {agent.agent_id}: {agent.role}{pm_info}\n"

        return snapshot

    # ==================== Team Management ====================

    def notify_pm(self, agent_id: str, message_type: str, message: str) -> bool:
        """Send a notification from an agent to their PM."""
        agent = self.registry.get_agent(agent_id)
        if not agent or not agent.pm_window:
            print(f"Agent {agent_id} has no PM assigned")
            return False

        timestamp = datetime.now().strftime("%Y-%m-%d %H:%M:%S")
        formatted = f"[{message_type}] from {agent_id} at {timestamp}: {message}"

        return self.send_message_to_agent(agent.pm_window, formatted)

    def broadcast_to_team(self, pm_id: str, message: str) -> Dict[str, bool]:
        """Send a message to all agents reporting to a PM."""
        team = self.registry.get_team_for_pm(pm_id)
        results = {}

        for agent in team:
            results[agent.agent_id] = self.send_message_to_agent(agent.agent_id, message)

        return results

    def check_team_status(self, pm_id: str, num_lines: int = 20) -> Dict[str, str]:
        """Capture recent output from all team members."""
        team = self.registry.get_team_for_pm(pm_id)
        status = {}

        for agent in team:
            status[agent.agent_id] = self.capture_agent_output(agent.agent_id, num_lines)

        return status


if __name__ == "__main__":
    orchestrator = TmuxOrchestrator()

    # Disable safety mode for testing
    orchestrator.safety_mode = False

    # Print status
    status = orchestrator.get_all_windows_status()
    print(json.dumps(status, indent=2))

    # Print monitoring snapshot
    print("\n" + orchestrator.create_monitoring_snapshot())
