"""
Shared role detection for hook scripts.

Detects the current agent's role by scanning identity.yml files in the project's
.workflow/ directory and matching against the current tmux session + window.

Detection chain:
1. Find project root (via HOOK_CWD or file path)
2. Scan .workflow/*/agents/*/identity.yml files
3. Match by tmux session name + window index
4. Return the role from the matching identity.yml
"""

import os
import subprocess
from pathlib import Path
from typing import Optional, Tuple

import yaml


def _safe_int(value) -> Optional[int]:
    """Safely convert a value to int, returning None on failure."""
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


def _tmux_cmd(*args) -> list:
    """Build a tmux command, respecting TMUX_SOCKET env var for custom sockets."""
    socket = os.environ.get("TMUX_SOCKET")
    base = ["tmux", "-L", socket] if socket else ["tmux"]
    return base + list(args)


def _get_tmux_session_name() -> Optional[str]:
    """Get the current tmux session name."""
    if not os.environ.get("TMUX"):
        return None
    pane_id = os.environ.get("TMUX_PANE")
    try:
        if pane_id:
            cmd = _tmux_cmd("display-message", "-t", pane_id, "-p", "#{session_name}")
        else:
            cmd = _tmux_cmd("display-message", "-p", "#{session_name}")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
        if result.returncode == 0:
            return result.stdout.strip() or None
    except Exception:
        pass
    return None


def _get_tmux_window_pane() -> Tuple[Optional[int], Optional[int]]:
    """Get current tmux window index and pane index."""
    pane_id = os.environ.get("TMUX_PANE")
    try:
        if pane_id:
            cmd = _tmux_cmd("display-message", "-t", pane_id, "-p", "#{window_index}:#{pane_index}")
        else:
            cmd = _tmux_cmd("display-message", "-p", "#{window_index}:#{pane_index}")
        result = subprocess.run(cmd, capture_output=True, text=True, timeout=2)
        if result.returncode == 0:
            parts = result.stdout.strip().split(":")
            if len(parts) == 2:
                return int(parts[0]), int(parts[1])
    except Exception:
        pass
    return None, None


def find_project_root_from_path(file_path: str) -> Optional[Path]:
    """Find project root by searching upward from a file path for .workflow/ directory."""
    path = Path(file_path)
    if not path.is_absolute():
        path = Path.cwd() / path
    current = path.parent

    while current != current.parent:
        if (current / ".workflow").exists():
            return current
        current = current.parent
    return None


def find_project_root_from_cwd() -> Optional[Path]:
    """Find project root using HOOK_CWD env var or CWD."""
    hook_cwd = os.environ.get("HOOK_CWD")
    if hook_cwd:
        current = Path(hook_cwd)
    else:
        current = Path.cwd()
    while current != current.parent:
        if (current / ".workflow").exists():
            return current
        current = current.parent
    return None


def _get_workflow_name() -> Optional[str]:
    """Get workflow name from environment or tmux env."""
    name = os.environ.get("WORKFLOW_NAME")
    if name:
        return name

    if os.environ.get("TMUX"):
        try:
            result = subprocess.run(
                _tmux_cmd("showenv", "WORKFLOW_NAME"),
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0 and "=" in result.stdout:
                name = result.stdout.strip().split("=", 1)[1]
                if name:
                    return name
        except Exception:
            pass

    return None


def detect_role(project_root: Optional[Path] = None, file_path: Optional[str] = None) -> Optional[str]:
    """
    Detect the current agent's role by scanning identity.yml files.

    Primary: matches pane_id from identity.yml against TMUX_PANE env var.
    Fallback: matches session + window (for legacy identity.yml without pane_id).

    Args:
        project_root: Project root path (if already known)
        file_path: File being edited (used to find project root if not provided)

    Returns:
        Role string (e.g., "pm", "developer", "qa") or None
    """
    if not os.environ.get("TMUX"):
        return None

    # Find project root
    if not project_root:
        if file_path:
            project_root = find_project_root_from_path(file_path)
        else:
            project_root = find_project_root_from_cwd()

    if not project_root:
        return None

    workflow_dir = project_root / ".workflow"
    if not workflow_dir.exists():
        return None

    # Get current tmux pane ID from environment (set by tmux automatically)
    current_pane_id = os.environ.get("TMUX_PANE")

    # Get current tmux session and window (for legacy fallback)
    current_session = _get_tmux_session_name()
    current_window, current_pane = _get_tmux_window_pane()

    # Determine which workflow to scan
    workflow_name = _get_workflow_name()
    scan_dirs = []

    if workflow_name:
        candidate = workflow_dir / workflow_name
        if candidate.exists():
            scan_dirs.append(candidate)

    # Fallback: scan most recent numbered workflow
    if not scan_dirs:
        for wf_dir in sorted(workflow_dir.glob("[0-9][0-9][0-9]-*"), reverse=True):
            if wf_dir.is_dir():
                scan_dirs.append(wf_dir)
                break

    # Scan identity.yml files
    for wf_dir in scan_dirs:
        agents_dir = wf_dir / "agents"
        if not agents_dir.exists():
            continue

        for identity_file in agents_dir.glob("*/identity.yml"):
            try:
                with open(identity_file) as f:
                    data = yaml.safe_load(f)

                if not data or not isinstance(data, dict):
                    continue

                role = data.get("role", "")
                if not role:
                    continue

                # Primary: match pane_id against TMUX_PANE
                identity_pane_id = data.get("pane_id")
                if identity_pane_id and current_pane_id:
                    if str(identity_pane_id) == str(current_pane_id):
                        return role.lower()
                    continue  # pane_id set but doesn't match - skip legacy check

                # Legacy fallback: match session + window
                identity_session = data.get("session", "")
                identity_window = _safe_int(data.get("window"))

                if not identity_session or identity_window is None:
                    continue

                if current_session and current_window is not None:
                    if str(identity_session) == str(current_session) and identity_window == current_window:
                        return role.lower()

            except Exception:
                continue

    return None
