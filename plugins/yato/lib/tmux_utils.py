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

import os
import re
import subprocess
import json
import tempfile
import time
from typing import List, Dict, Optional, Tuple
from dataclasses import dataclass
from datetime import datetime


def validate_pane_id(pane_id: str) -> bool:
    """Validate that a pane_id matches the expected %N format.

    Args:
        pane_id: String to validate (e.g., "%5", "%12")

    Returns:
        True if valid %N format, False otherwise
    """
    return bool(re.match(r'^%\d+$', pane_id))


def _build_message_with_suffixes(message: str, yato_suffix: str, workflow_suffix: str) -> str:
    """
    Build a message with yato-level and workflow-level suffixes stacked.

    Both suffixes are appended if set (no fallback, they stack).
    Ordering: original message, then yato-level suffix, then workflow-level suffix.
    Each suffix is separated by a blank line.

    Args:
        message: The original message
        yato_suffix: Yato-level suffix from defaults.conf
        workflow_suffix: Workflow-level suffix from status.yml

    Returns:
        Message with suffixes appended
    """
    result = message
    if yato_suffix:
        result = result + "\n\n" + yato_suffix
    if workflow_suffix:
        result = result + "\n\n" + workflow_suffix
    return result


def _tmux_cmd() -> list:
    """Return tmux command with optional -L socket flag from TMUX_SOCKET env var."""
    socket = os.environ.get("TMUX_SOCKET")
    if socket:
        return ["tmux", "-L", socket]
    return ["tmux"]


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
            sessions_cmd = _tmux_cmd() + ["list-sessions", "-F", "#{session_name}:#{session_attached}"]
            sessions_result = subprocess.run(sessions_cmd, capture_output=True, text=True, check=True)

            sessions = []
            for line in sessions_result.stdout.strip().split('\n'):
                if not line:
                    continue
                session_name, attached = line.split(':')

                # Get windows for this session
                windows_cmd = _tmux_cmd() + ["list-windows", "-t", session_name, "-F", "#{window_index}:#{window_name}:#{window_active}"]
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
            _tmux_cmd() + ["has-session", "-t", session_name],
            capture_output=True
        )
        return result.returncode == 0

    def create_session(self, name: str, path: Optional[str] = None) -> bool:
        """Create a new tmux session."""
        cmd = _tmux_cmd() + ["new-session", "-d", "-s", name]
        if path:
            cmd.extend(["-c", path])

        result = subprocess.run(cmd, capture_output=True)
        return result.returncode == 0

    def create_window(self, session: str, name: str, path: Optional[str] = None) -> Optional[Dict[str, str]]:
        """Create a new window in a session, returning window index and pane_id.

        Returns:
            Dict with 'window_index' (int) and 'pane_id' (str like '%5'), or None on failure.
        """
        cmd = _tmux_cmd() + ["new-window", "-d", "-t", session, "-n", name, "-P", "-F", "#{window_index}:#{pane_id}"]
        if path:
            cmd.extend(["-c", path])

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            return None

        try:
            output = result.stdout.strip()
            parts = output.split(":", 1)
            return {
                "window_index": int(parts[0]),
                "pane_id": parts[1] if len(parts) > 1 else "",
            }
        except (ValueError, IndexError):
            return None

    def set_pane_title(self, target: str, title: str) -> bool:
        """Set a title for a pane (requires pane-border-format to show)."""
        # Select the pane and set its title
        cmd = _tmux_cmd() + ["select-pane", "-t", target, "-T", title]
        result = subprocess.run(cmd, capture_output=True, text=True)
        return result.returncode == 0

    # ==================== Content Capture ====================

    def capture_window_content(self, session_name: str, window_index: int, num_lines: int = 50) -> str:
        """Safely capture the last N lines from a tmux window."""
        if num_lines > self.max_lines_capture:
            num_lines = self.max_lines_capture

        try:
            cmd = _tmux_cmd() + ["capture-pane", "-t", f"{session_name}:{window_index}", "-p", "-S", f"-{num_lines}"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout
        except subprocess.CalledProcessError as e:
            return f"Error capturing window content: {e}"

    def capture_agent_output(self, agent_id: str, num_lines: int = 50) -> str:
        """Capture output from an agent target.

        Supports %N pane ID, window format (session:window), and pane format (session:window.pane).
        """
        # Handle %N pane ID format
        if agent_id.startswith("%"):
            return self._capture_pane_content(agent_id, num_lines)

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
            cmd = _tmux_cmd() + ["capture-pane", "-t", target, "-p", "-S", f"-{num_lines}"]
            result = subprocess.run(cmd, capture_output=True, text=True, check=True)
            return result.stdout
        except subprocess.CalledProcessError as e:
            return f"Error capturing pane content: {e}"

    def get_window_info(self, session_name: str, window_index: int) -> Dict:
        """Get detailed information about a specific window."""
        try:
            cmd = _tmux_cmd() + ["display-message", "-t", f"{session_name}:{window_index}", "-p",
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

    def send_message(self, target: str, message: str, enter: bool = True, workflow_status_file: str = None, _skip_suffix: bool = False) -> bool:
        """
        Send a message to a tmux target (%N pane ID, session:window, or session:window.pane).

        This is the primary message sending function, matching send-message.sh behavior:
        1. Use target directly if it's a %N pane ID, otherwise default to pane 0
        2. Select the target pane to ensure it's active
        3. Exit copy mode if active (prevents search mode trigger from / in paths)
        4. Wait briefly for UI
        5. Send the message text as literal (-l flag)
        6. Send Enter immediately to submit (no delay to avoid TUI state changes)

        Args:
            target: Target in format "%N" (pane ID), "session:window", or "session:window.pane"
            message: The message text to send
            enter: Whether to send Enter after the message (default True)
            workflow_status_file: Path to workflow status.yml for per-project agent_message_suffix
            _skip_suffix: Internal flag to skip suffix handling (used by notify_pm)

        Returns:
            True if successful, False otherwise
        """
        try:
            tmux = _tmux_cmd()

            # Step 1: Use target directly if %N pane ID, otherwise default to pane 0
            if not target.startswith("%"):
                if "." not in target:
                    target = f"{target}.0"

            # Step 2: Select the target pane to ensure it's active
            subprocess.run(
                tmux + ["select-pane", "-t", target],
                capture_output=True,
                check=False  # Don't fail if pane can't be selected
            )

            # Step 3: Exit copy mode if active (prevents / triggering search)
            subprocess.run(
                tmux + ["send-keys", "-t", target, "-X", "cancel"],
                capture_output=True,
                check=False  # Don't fail if not in copy mode
            )

            # Step 4: Brief wait for UI
            time.sleep(0.5)

            # Step 4.5: Append stacked suffixes (yato-level + workflow-level)
            if not _skip_suffix:
                try:
                    from lib.config import get as get_config
                except ImportError:
                    import importlib.util
                    _cfg_path = os.path.join(os.path.dirname(__file__), "config.py")
                    _spec = importlib.util.spec_from_file_location("config", _cfg_path)
                    _cfg = importlib.util.module_from_spec(_spec)
                    _spec.loader.exec_module(_cfg)
                    get_config = _cfg.get
                yato_suffix = get_config("PM_TO_AGENTS_SUFFIX")

                workflow_suffix = ""
                if workflow_status_file:
                    from pathlib import Path
                    import yaml
                    _wf_path = Path(workflow_status_file)
                    if _wf_path.exists():
                        with open(_wf_path) as f:
                            data = yaml.safe_load(f)
                        if data and isinstance(data, dict):
                            workflow_suffix = data.get("agent_message_suffix", "")

                message = _build_message_with_suffixes(message, yato_suffix, workflow_suffix)

            # Step 5: Send the message text
            # Use bracketed paste (load-buffer + paste-buffer -p) for messages with newlines.
            # tmux send-keys -l treats \n as Enter keypresses, which submits the prompt
            # prematurely and collapses multi-line content into a single line.
            # Bracketed paste preserves newlines as actual line content in the TUI.
            if "\n" in message:
                with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
                    f.write(message)
                    tmp_path = f.name
                try:
                    buf_name = f"yato-msg-{os.getpid()}"
                    result = subprocess.run(
                        tmux + ["load-buffer", "-b", buf_name, tmp_path],
                        capture_output=True, text=True,
                    )
                    if result.returncode != 0:
                        print(f"Error loading buffer: {result.stderr}")
                        return False
                    result = subprocess.run(
                        tmux + ["paste-buffer", "-p", "-d", "-b", buf_name, "-t", target],
                        capture_output=True, text=True,
                    )
                    if result.returncode != 0:
                        print(f"Error pasting buffer: {result.stderr}")
                        return False
                finally:
                    os.unlink(tmp_path)
            else:
                cmd = tmux + ["send-keys", "-l", "-t", target, message]
                result = subprocess.run(cmd, capture_output=True, text=True)
                if result.returncode != 0:
                    print(f"Error sending message: {result.stderr}")
                    return False

            if enter:
                # Step 6: Brief delay to let TUI process text before submitting
                time.sleep(0.5)

                cmd = tmux + ["send-keys", "-t", target, "Enter"]
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
            cmd = _tmux_cmd() + ["send-keys", "-t", f"{session_name}:{window_index}", keys]
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
            cmd = _tmux_cmd() + ["send-keys", "-t", f"{session_name}:{window_index}", "Enter"]
            subprocess.run(cmd, check=True)
            return True
        except subprocess.CalledProcessError as e:
            print(f"Error sending Enter key: {e}")
            return False

    def send_message_to_agent(self, agent_id: str, message: str, confirm: bool = False) -> bool:
        """Send a message to an agent target.

        Supports %N pane ID, window format (session:window), and pane format (session:window.pane).
        """
        # Handle %N pane ID format
        if agent_id.startswith("%"):
            return self._send_to_pane(agent_id, message, confirm)

        if ":" not in agent_id:
            print(f"Invalid agent_id format: {agent_id}")
            return False

        session, target = agent_id.split(":", 1)

        # Check if target includes a pane (e.g., "0.1")
        if "." in target:
            return self._send_to_pane(agent_id, message, confirm)

        try:
            window_idx = int(target)
        except ValueError:
            print(f"Invalid window index in agent_id: {agent_id}")
            return False

        return self.send_command_to_window(session, window_idx, message, confirm)

    def _send_to_pane(self, target: str, message: str, confirm: bool = False) -> bool:
        """Send a message to a specific pane target (session:window.pane).

        Uses bracketed paste for multi-line messages to preserve newlines.
        """
        if self.safety_mode and confirm:
            print(f"SAFETY CHECK: About to send '{message}' to {target}")
            response = input("Confirm? (yes/no): ")
            if response.lower() != 'yes':
                print("Operation cancelled")
                return False

        try:
            tmux = _tmux_cmd()
            if "\n" in message:
                with tempfile.NamedTemporaryFile(mode="w", suffix=".txt", delete=False) as f:
                    f.write(message)
                    tmp_path = f.name
                try:
                    buf_name = f"yato-pane-{os.getpid()}"
                    subprocess.run(tmux + ["load-buffer", "-b", buf_name, tmp_path], check=True)
                    subprocess.run(tmux + ["paste-buffer", "-p", "-d", "-b", buf_name, "-t", target], check=True)
                finally:
                    os.unlink(tmp_path)
            else:
                cmd = tmux + ["send-keys", "-l", "-t", target, message]
                subprocess.run(cmd, check=True)

            # Wait before sending Enter
            time.sleep(self.message_delay)

            # Send Enter
            cmd = tmux + ["send-keys", "-t", target, "Enter"]
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


def send_message(target: str, message: str, enter: bool = True, workflow_status_file: str = None, _skip_suffix: bool = False) -> bool:
    """
    Send a message to a tmux target.

    This is a convenience function that wraps TmuxOrchestrator.send_message().

    Args:
        target: Target in format "%N" (pane ID), "session:window", or "session:window.pane"
        message: The message text to send
        enter: Whether to send Enter after the message (default True)
        workflow_status_file: Path to workflow status.yml for per-project agent_message_suffix
        _skip_suffix: Internal flag to skip suffix handling (used by notify_pm)

    Returns:
        True if successful, False otherwise
    """
    return _get_orchestrator().send_message(target, message, enter, workflow_status_file, _skip_suffix)


def get_current_session() -> Optional[str]:
    """
    Get the current tmux session name.

    Returns:
        Session name if running in tmux, None otherwise
    """
    try:
        result = subprocess.run(
            _tmux_cmd() + ["display-message", "-p", "#S"],
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
                   Defaults to YATO_PATH env var or auto-detected from __file__.

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
        yato_path = os.environ.get("YATO_PATH", str(Path(__file__).resolve().parent.parent))

    print(f"Restarting check-in display in {target}...")

    try:
        # Kill any existing process in the pane (Ctrl-C)
        subprocess.run(_tmux_cmd() + ["send-keys", "-t", target, "C-c"], check=False)
        time.sleep(0.3)

        # Clear the pane
        subprocess.run(_tmux_cmd() + ["send-keys", "-t", target, "clear", "Enter"], check=True)
        time.sleep(0.2)

        # Start the display script
        # For now, call the bash script. This will be replaced with Python later.
        display_script = f"{yato_path}/bin/checkin-display.sh"
        subprocess.run(_tmux_cmd() + ["send-keys", "-t", target, f"bash {display_script}", "Enter"], check=True)

        print(f"Check-in display restarted in {target}")
        return True

    except subprocess.CalledProcessError as e:
        print(f"Error restarting check-in display: {e}")
        return False


def notify_pm(message: str, session: Optional[str] = None, workflow_status_file: Optional[str] = None, skip_suffix: bool = False) -> bool:
    """
    Send a notification message to the Project Manager.

    Looks up PM pane_id from agents.yml. Falls back to session:0.1 if not found.

    Appends stacked suffixes (yato-level AGENTS_TO_PM_SUFFIX + workflow-level
    agent_to_pm_message_suffix) before sending.

    Message format conventions:
    - [DONE] - Task completed
    - [BLOCKED] - Blocked on something
    - [HELP] - Need assistance
    - [STATUS] - Status update
    - [PROGRESS] - Progress report

    Args:
        message: The notification message (can include prefix like [DONE])
        session: Session name (auto-detected if not provided)
        workflow_status_file: Path to workflow status.yml for workflow-level suffix
        skip_suffix: If True, skip appending AGENTS_TO_PM_SUFFIX and workflow suffix

    Returns:
        True if successful, False otherwise
    """
    if session is None:
        session = get_current_session()
        if session is None:
            print("Error: Not running in a tmux session and no session specified")
            return False

    # Build message with agent->PM suffixes
    try:
        from lib.config import get as get_config
    except ImportError:
        import importlib.util
        _cfg_path = os.path.join(os.path.dirname(__file__), "config.py")
        _spec = importlib.util.spec_from_file_location("config", _cfg_path)
        _cfg = importlib.util.module_from_spec(_spec)
        _spec.loader.exec_module(_cfg)
        get_config = _cfg.get
    yato_suffix = get_config("AGENTS_TO_PM_SUFFIX")

    workflow_suffix = ""
    if workflow_status_file:
        from pathlib import Path
        import yaml
        _wf_path = Path(workflow_status_file)
        if _wf_path.exists():
            with open(_wf_path) as f:
                data = yaml.safe_load(f)
            if data and isinstance(data, dict):
                workflow_suffix = data.get("agent_to_pm_message_suffix", "")

    if not skip_suffix:
        message = _build_message_with_suffixes(message, yato_suffix, workflow_suffix)

    # Look up PM pane_id from agents.yml
    pm_target = _lookup_pm_pane_id(session, workflow_status_file)

    # Use _skip_suffix=True since we already handled suffixes above
    return send_message(pm_target, message, _skip_suffix=True)


def _lookup_pm_pane_id(session: str, workflow_status_file: Optional[str] = None) -> str:
    """Look up PM pane_id from agents.yml. Falls back to session:0.1."""
    from pathlib import Path
    import yaml

    # Try to find workflow path from workflow_status_file
    workflow_path = None
    if workflow_status_file:
        workflow_path = Path(workflow_status_file).parent
    else:
        # Try WORKFLOW_NAME from tmux env
        workflow_name = None
        try:
            result = subprocess.run(
                _tmux_cmd() + ["showenv", "WORKFLOW_NAME"],
                capture_output=True, text=True, check=True,
            )
            output = result.stdout.strip()
            if "=" in output:
                workflow_name = output.split("=", 1)[1]
        except subprocess.CalledProcessError:
            pass

        if workflow_name:
            # Search upward from cwd for .workflow/
            current = Path.cwd()
            while current != current.parent:
                candidate = current / ".workflow" / workflow_name
                if candidate.exists():
                    workflow_path = candidate
                    break
                current = current.parent

    if workflow_path:
        agents_file = workflow_path / "agents.yml"
        if agents_file.exists():
            try:
                with open(agents_file) as f:
                    data = yaml.safe_load(f)
                if data and isinstance(data, dict):
                    pm_data = data.get("pm", {})
                    pm_pane_id = pm_data.get("pane_id")
                    if pm_pane_id and validate_pane_id(str(pm_pane_id)):
                        return str(pm_pane_id)
            except Exception:
                pass

    # Fallback: session:0.1
    return f"{session}:0.1"


def send_to_agent(agent_name: str, message: str, session: Optional[str] = None, workflow_status_file: Optional[str] = None) -> bool:
    """
    Send a message to a named agent by looking up its target from agents.yml.

    Resolves the agent's session:window.pane from agents.yml and sends the message
    via send_message() which auto-handles PM_TO_AGENTS_SUFFIX stacking.

    Args:
        agent_name: Agent name as defined in agents.yml
        message: The message to send
        session: Session name (auto-detected if not provided)
        workflow_status_file: Path to workflow status.yml for workflow-level suffix

    Returns:
        True if successful, False otherwise
    """
    from pathlib import Path
    import yaml

    if session is None:
        session = get_current_session()
        if session is None:
            print("Error: Not running in a tmux session and no session specified")
            return False

    # Find workflow path
    workflow_name = None
    try:
        result = subprocess.run(
            _tmux_cmd() + ["showenv", "WORKFLOW_NAME"],
            capture_output=True, text=True, check=True,
        )
        output = result.stdout.strip()
        if "=" in output:
            workflow_name = output.split("=", 1)[1]
    except subprocess.CalledProcessError:
        pass

    if not workflow_name:
        print("Error: WORKFLOW_NAME not set in tmux environment")
        return False

    # Search upward from cwd for .workflow/ containing the workflow
    project_root = None
    current = Path.cwd()
    while current != current.parent:
        workflow_dir = current / ".workflow" / workflow_name
        if workflow_dir.exists():
            project_root = current
            break
        current = current.parent

    # Fallback: try pane's working directory
    if project_root is None:
        try:
            result = subprocess.run(
                _tmux_cmd() + ["display-message", "-p", "#{pane_current_path}"],
                capture_output=True, text=True, check=False,
            )
            pane_path = result.stdout.strip()
            if pane_path:
                current = Path(pane_path)
                while current != current.parent:
                    workflow_dir = current / ".workflow" / workflow_name
                    if workflow_dir.exists():
                        project_root = current
                        break
                    current = current.parent
        except Exception:
            pass

    if project_root is None:
        print(f"Error: No .workflow/{workflow_name} directory found")
        return False

    workflow_path = project_root / ".workflow" / workflow_name
    agents_file = workflow_path / "agents.yml"

    if not agents_file.exists():
        print(f"Error: agents.yml not found at {agents_file}")
        return False

    # Look up agent target
    with open(agents_file) as f:
        data = yaml.safe_load(f)

    agent_target = None
    for agent in data.get("agents", []):
        if agent.get("name") == agent_name:
            # Prefer pane_id (global tmux pane ID like "%12")
            pane_id = agent.get("pane_id")
            if pane_id and validate_pane_id(str(pane_id)):
                agent_target = str(pane_id)
            else:
                # Fallback to session:window
                agent_session = agent.get("session", session)
                window = agent.get("window", "")
                agent_target = f"{agent_session}:{window}"
            break

    if not agent_target:
        available = [f"  - {a.get('name', '?')} ({a.get('role', '?')}) at window {a.get('window', '?')}" for a in data.get("agents", [])]
        print(f"Error: Agent '{agent_name}' not found in agents.yml")
        if available:
            print("Available agents:")
            print("\n".join(available))
        return False

    # Auto-detect workflow_status_file if not provided
    if workflow_status_file is None:
        status_file = workflow_path / "status.yml"
        if status_file.exists():
            workflow_status_file = str(status_file)

    return send_message(agent_target, message, workflow_status_file=workflow_status_file)


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
    send_parser.add_argument("--skip-suffix", action="store_true", help="Skip appending PM_TO_AGENTS_SUFFIX")

    # notify command
    notify_parser = subparsers.add_parser("notify", help="Notify PM")
    notify_parser.add_argument("message", nargs="+", help="Message to send to PM")
    notify_parser.add_argument("--session", "-s", help="Session name (auto-detected if not provided)")
    notify_parser.add_argument("--workflow-status-file", help="Path to workflow status.yml for suffix")

    # send-to-agent command
    send_to_agent_parser = subparsers.add_parser("send-to-agent", help="Send message to named agent")
    send_to_agent_parser.add_argument("agent_name", help="Agent name from agents.yml")
    send_to_agent_parser.add_argument("message", nargs="+", help="Message to send")
    send_to_agent_parser.add_argument("--session", "-s", help="Session name (auto-detected if not provided)")

    # restart-checkin-display command
    restart_parser = subparsers.add_parser("restart-checkin-display", help="Restart check-in display")
    restart_parser.add_argument("--target", "-t", help="Target window (session:window), auto-detected if not provided")
    restart_parser.add_argument("--yato-path", help="Path to yato installation")

    # status command
    status_parser = subparsers.add_parser("status", help="Show tmux status")

    args = parser.parse_args()

    if args.command == "send":
        message = " ".join(args.message)
        success = send_message(args.target, message, enter=not args.no_enter, _skip_suffix=args.skip_suffix)
        if success:
            print(f"Message sent to {args.target}: {message}")
        else:
            print(f"Failed to send message to {args.target}")
            sys.exit(1)
    elif args.command == "notify":
        message = " ".join(args.message)
        success = notify_pm(message, session=args.session, workflow_status_file=args.workflow_status_file)
        if success:
            print(f"Notification sent to PM: {message}")
        else:
            print("Failed to notify PM")
            sys.exit(1)
    elif args.command == "send-to-agent":
        message = " ".join(args.message)
        success = send_to_agent(args.agent_name, message, session=args.session)
        if success:
            print(f"Message sent to agent '{args.agent_name}': {message}")
        else:
            print(f"Failed to send message to agent '{args.agent_name}'")
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
