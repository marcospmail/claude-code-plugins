#!/usr/bin/env python3
"""
Yato Tmux Utilities - Python utilities for tmux operations.

This module provides a comprehensive interface for:
- Managing tmux sessions and windows
- Capturing and analyzing window content
- Sending messages to agents

Note: Registry operations have been moved to WorkflowRegistry.
This module focuses on pure tmux operations only.
"""

import subprocess
import json
import time
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime


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

    Note: Registry operations have been moved to WorkflowRegistry.
    """

    def __init__(self):
        self.safety_mode = True
        self.max_lines_capture = 1000
        self.message_delay = 0.5  # Delay between message and Enter

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
        cmd = ["tmux", "new-window", "-d", "-t", session, "-n", name, "-P", "-F", "#{window_index}"]
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
        """Capture output from an agent target.

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

    def send_message(self, target: str, message: str, enter: bool = True) -> bool:
        """
        Send a message to a tmux target (session:window or session:window.pane).

        This is the primary message sending function, matching send-message.sh behavior:
        1. Select the target pane to ensure it's active
        2. Exit copy mode if active (prevents search mode trigger from / in paths)
        3. Wait briefly for UI
        4. Send the message text
        5. Wait for UI to process
        6. Optionally send Enter to submit

        Args:
            target: Target in format "session:window" or "session:window.pane"
            message: The message text to send
            enter: Whether to send Enter after the message (default True)

        Returns:
            True if successful, False otherwise
        """
        try:
            # Step 1: Select the target pane to ensure it's active
            subprocess.run(
                ["tmux", "select-pane", "-t", target],
                capture_output=True,
                check=False  # Don't fail if pane can't be selected
            )

            # Step 2: Exit copy mode if active (prevents / triggering search)
            subprocess.run(
                ["tmux", "send-keys", "-t", target, "-X", "cancel"],
                capture_output=True,
                check=False  # Don't fail if not in copy mode
            )

            # Step 3: Brief wait for UI
            time.sleep(0.5)

            # Step 4: Send the message text
            cmd = ["tmux", "send-keys", "-t", target, message]
            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Error sending message: {result.stderr}")
                return False

            if enter:
                # Step 5: Wait for UI to process the text
                time.sleep(1.0)

                # Step 6: Send Enter to submit
                cmd = ["tmux", "send-keys", "-t", target, "Enter"]
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"Error sending Enter: {result.stderr}")
                    return False

            return True

        except Exception as e:
            print(f"Error in send_message: {e}")
            return False

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
        """Send a message to an agent target.

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

                window_data = {
                    "index": window.window_index,
                    "name": window.window_name,
                    "active": window.active,
                    "info": window_info
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
        snapshot = f"Yato Monitoring Snapshot - {status['timestamp']}\n"
        snapshot += "=" * 60 + "\n\n"

        for session in status['sessions']:
            snapshot += f"Session: {session['name']} ({'ATTACHED' if session['attached'] else 'DETACHED'})\n"
            snapshot += "-" * 40 + "\n"

            for window in session['windows']:
                snapshot += f"  Window {window['index']}: {window['name']}"
                if window['active']:
                    snapshot += " (ACTIVE)"

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

        return snapshot


# ==================== Module-level functions ====================
# These provide simple function-based interface without needing to instantiate the class

_default_orchestrator = None


def _get_orchestrator() -> TmuxOrchestrator:
    """Get or create the default orchestrator instance."""
    global _default_orchestrator
    if _default_orchestrator is None:
        _default_orchestrator = TmuxOrchestrator()
        _default_orchestrator.safety_mode = False
    return _default_orchestrator


def send_message(target: str, message: str, enter: bool = True) -> bool:
    """
    Send a message to a tmux target.

    This is a convenience function that wraps TmuxOrchestrator.send_message().

    Args:
        target: Target in format "session:window" or "session:window.pane"
        message: The message text to send
        enter: Whether to send Enter after the message (default True)

    Returns:
        True if successful, False otherwise
    """
    return _get_orchestrator().send_message(target, message, enter)


def get_current_session() -> Optional[str]:
    """
    Get the current tmux session name.

    Returns:
        Session name if running in tmux, None otherwise
    """
    try:
        result = subprocess.run(
            ["tmux", "display-message", "-p", "#S"],
            capture_output=True,
            text=True,
            check=True
        )
        session = result.stdout.strip()
        return session if session else None
    except subprocess.CalledProcessError:
        return None


def restart_checkin_display(target: Optional[str] = None, yato_path: Optional[str] = None) -> bool:
    """
    Restart the check-in display in pane 0 of the PM window.

    The check-in display runs in pane 0 of window 0, showing scheduled check-ins.

    Args:
        target: Target window (session:window), auto-detected if not provided.
                Pane 0 will be used automatically.
        yato_path: Path to yato installation (for finding checkin-display.sh).
                   Defaults to YATO_PATH env var or ~/dev/tools/yato.

    Returns:
        True if successful, False otherwise
    """
    # Determine target
    if target is None:
        session = get_current_session()
        if session is None:
            print("Error: Not in tmux and no target specified")
            return False
        target = f"{session}:0"

    # Add pane 0 if not specified
    if "." not in target:
        target = f"{target}.0"

    # Determine yato path
    if yato_path is None:
        import os
        yato_path = os.environ.get("YATO_PATH", os.path.expanduser("~/dev/tools/yato"))

    print(f"Restarting check-in display in {target}...")

    try:
        # Kill any existing process in the pane (Ctrl-C)
        subprocess.run(["tmux", "send-keys", "-t", target, "C-c"], check=False)
        time.sleep(0.3)

        # Clear the pane
        subprocess.run(["tmux", "send-keys", "-t", target, "clear", "Enter"], check=True)
        time.sleep(0.2)

        # Start the display script
        # For now, call the bash script. This will be replaced with Python later.
        display_script = f"{yato_path}/bin/checkin-display.sh"
        subprocess.run(["tmux", "send-keys", "-t", target, f"bash {display_script}", "Enter"], check=True)

        print(f"Check-in display restarted in {target}")
        return True

    except subprocess.CalledProcessError as e:
        print(f"Error restarting check-in display: {e}")
        return False


def notify_pm(message: str, session: Optional[str] = None) -> bool:
    """
    Send a notification message to the Project Manager.

    PM is always at window 0, pane 1 (pane 0 is the check-ins display).

    Message format conventions:
    - [DONE] - Task completed
    - [BLOCKED] - Blocked on something
    - [HELP] - Need assistance
    - [STATUS] - Status update
    - [PROGRESS] - Progress report

    Args:
        message: The notification message (can include prefix like [DONE])
        session: Session name (auto-detected if not provided)

    Returns:
        True if successful, False otherwise
    """
    if session is None:
        session = get_current_session()
        if session is None:
            print("Error: Not running in a tmux session and no session specified")
            return False

    # PM is always at window 0, pane 1
    pm_target = f"{session}:0.1"
    return send_message(pm_target, message)


if __name__ == "__main__":
    import sys
    import argparse

    parser = argparse.ArgumentParser(description="Tmux utilities for Yato")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # send command
    send_parser = subparsers.add_parser("send", help="Send message to target")
    send_parser.add_argument("target", help="Target (session:window or session:window.pane)")
    send_parser.add_argument("message", nargs="+", help="Message to send")
    send_parser.add_argument("--no-enter", action="store_true", help="Don't send Enter after message")

    # notify command
    notify_parser = subparsers.add_parser("notify", help="Notify PM")
    notify_parser.add_argument("message", nargs="+", help="Message to send to PM")
    notify_parser.add_argument("--session", "-s", help="Session name (auto-detected if not provided)")

    # restart-checkin-display command
    restart_parser = subparsers.add_parser("restart-checkin-display", help="Restart check-in display")
    restart_parser.add_argument("--target", "-t", help="Target window (session:window), auto-detected if not provided")
    restart_parser.add_argument("--yato-path", help="Path to yato installation")

    # status command
    status_parser = subparsers.add_parser("status", help="Show tmux status")

    args = parser.parse_args()

    if args.command == "send":
        message = " ".join(args.message)
        success = send_message(args.target, message, enter=not args.no_enter)
        if success:
            print(f"Message sent to {args.target}: {message}")
        else:
            print(f"Failed to send message to {args.target}")
            sys.exit(1)
    elif args.command == "notify":
        message = " ".join(args.message)
        success = notify_pm(message, session=args.session)
        if success:
            session = args.session or get_current_session()
            print(f"Notification sent to PM ({session}:0.1): {message}")
        else:
            print("Failed to notify PM")
            sys.exit(1)
    elif args.command == "restart-checkin-display":
        success = restart_checkin_display(target=args.target, yato_path=args.yato_path)
        if not success:
            sys.exit(1)
    elif args.command == "status":
        orchestrator = TmuxOrchestrator()
        orchestrator.safety_mode = False
        status = orchestrator.get_all_windows_status()
        print(json.dumps(status, indent=2))
        print("\n" + orchestrator.create_monitoring_snapshot())
    else:
        parser.print_help()
