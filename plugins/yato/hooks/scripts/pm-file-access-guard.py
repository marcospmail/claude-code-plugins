#!/usr/bin/env python3
"""
PreToolUse hook that restricts PM from editing files outside the workflow directory.

PM agents should only be able to edit workflow-related files:
- .workflow/**/tasks.json
- .workflow/**/prd.md
- .workflow/**/status.yml
- .workflow/**/team.yml
- .workflow/**/agents.yml
- .workflow/**/checkins.json
- .workflow/**/agents/**/identity.yml
- .workflow/**/agents/**/instructions.md
- .workflow/**/agents/**/agent-tasks.md
- .workflow/**/agents/**/constraints.md
- .workflow/**/agents/**/constraints.example.md
- .workflow/**/agents/**/CLAUDE.md

If PM tries to edit source code, config files, or any other files,
the hook blocks the tool use and instructs PM to delegate to an agent.
"""

import fnmatch
import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Optional, Tuple

import yaml


def _safe_int(value) -> Optional[int]:
    """Safely convert a value to int, returning None on failure."""
    try:
        return int(value)
    except (ValueError, TypeError):
        return None


# Files that PM is allowed to write/edit (relative to project root)
PM_ALLOWED_PATTERNS = [
    # Workflow metadata
    ".workflow/*/tasks.json",
    ".workflow/*/prd.md",
    ".workflow/*/status.yml",
    ".workflow/*/team.yml",
    ".workflow/*/agents.yml",
    ".workflow/*/checkins.json",
    # Agent configuration files
    ".workflow/*/agents/*/identity.yml",
    ".workflow/*/agents/*/instructions.md",
    ".workflow/*/agents/*/agent-tasks.md",
    ".workflow/*/agents/*/constraints.md",
    ".workflow/*/agents/*/constraints.example.md",
    ".workflow/*/agents/*/CLAUDE.md",
    # Also allow writing to the workflow root
    ".workflow/current",
]


def find_project_root(file_path: str) -> Optional[Path]:
    """Find the project root by looking for .workflow/ directory.

    Searches upward from the file's directory (not CWD) because
    uv run --directory changes CWD to the plugin directory.
    """
    # Start from the file's directory, not CWD
    path = Path(file_path)
    if not path.is_absolute():
        path = Path.cwd() / path
    current = path.parent

    while current != current.parent:
        if (current / ".workflow").exists():
            return current
        current = current.parent
    return None


def _get_tmux_window_pane() -> Tuple[Optional[int], Optional[int]]:
    """Get current tmux window index and pane index.

    Uses TMUX_PANE env var (set per-pane by tmux) to target the correct pane.
    Without explicit targeting, display-message returns the active window's info,
    which is wrong when the command runs in a background window.
    """
    pane_id = os.environ.get("TMUX_PANE")
    try:
        cmd = ["tmux", "display-message", "-p", "#{window_index}:#{pane_index}"]
        if pane_id:
            cmd = ["tmux", "display-message", "-t", pane_id, "-p", "#{window_index}:#{pane_index}"]
        result = subprocess.run(
            cmd,
            capture_output=True,
            text=True,
            timeout=2,
        )
        if result.returncode == 0:
            parts = result.stdout.strip().split(":")
            if len(parts) == 2:
                return int(parts[0]), int(parts[1])
    except Exception:
        pass
    return None, None


def _get_workflow_name() -> Optional[str]:
    """Get workflow name from environment or tmux env."""
    name = os.environ.get("WORKFLOW_NAME")
    if name:
        return name

    if os.environ.get("TMUX"):
        try:
            result = subprocess.run(
                ["tmux", "showenv", "WORKFLOW_NAME"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0 and "=" in result.stdout:
                name = result.stdout.strip().split("=", 1)[1]
                if name:
                    return name
        except Exception:
            pass

    return None


def _detect_role_from_workflow(file_path: str) -> Optional[str]:
    """
    Detect agent role by matching current tmux window/pane to agents.yml.

    Finds the workflow's agents.yml from the project root (derived from
    the file being edited), then matches the current tmux window/pane
    to determine which agent we are.
    """
    try:
        project_root = find_project_root(file_path)
        if not project_root:
            return None

        workflow_dir = project_root / ".workflow"
        if not workflow_dir.exists():
            return None

        # Find agents.yml: try specific workflow first, then most recent
        agents_file = None
        workflow_name = _get_workflow_name()
        if workflow_name:
            candidate = workflow_dir / workflow_name / "agents.yml"
            if candidate.exists():
                agents_file = candidate

        if not agents_file:
            for wf_dir in sorted(workflow_dir.glob("[0-9][0-9][0-9]-*"), reverse=True):
                candidate = wf_dir / "agents.yml"
                if candidate.exists():
                    agents_file = candidate
                    break

        if not agents_file or not agents_file.exists():
            return None

        with open(agents_file) as f:
            data = yaml.safe_load(f)

        if not data:
            return None

        current_window, current_pane = _get_tmux_window_pane()
        if current_window is None:
            return None

        # Check PM entry (matches on both window AND pane since PM shares window 0)
        pm_data = data.get("pm", {})
        if pm_data:
            pm_window = _safe_int(pm_data.get("window"))
            pm_pane = _safe_int(pm_data.get("pane"))
            if pm_window is not None and pm_window == current_window:
                if pm_pane is not None:
                    if pm_pane == current_pane:
                        return pm_data.get("role", "pm").lower()
                else:
                    return pm_data.get("role", "pm").lower()

        # Check agent entries (match window, and pane if specified for single-window mode)
        for agent in data.get("agents", []):
            agent_window = _safe_int(agent.get("window"))
            if agent_window is not None and agent_window == current_window:
                agent_pane = _safe_int(agent.get("pane"))
                if agent_pane is not None:
                    if agent_pane == current_pane:
                        return agent.get("role", "").lower()
                else:
                    return agent.get("role", "").lower()

        return None
    except Exception:
        return None


def get_agent_role(file_path: Optional[str] = None) -> Optional[str]:
    """
    Determine the current agent's role.

    Detection chain:
    1. AGENT_ROLE environment variable (explicit override)
    2. Workflow-based detection: match current tmux window/pane against agents.yml
    3. identity.yml in current directory (legacy fallback)
    """
    # 1. Check environment variable first (explicit override, backwards compat)
    # Note: If AGENT_ROLE is in environ but empty, that means "no role" (skip further checks)
    if "AGENT_ROLE" in os.environ:
        role = os.environ["AGENT_ROLE"]
        if role:
            return role.lower()
        return None

    # 2. Workflow-based detection via agents.yml + tmux window matching
    if os.environ.get("TMUX") and file_path:
        role = _detect_role_from_workflow(file_path)
        if role:
            return role

    # 3. Legacy fallback: identity.yml in CWD
    identity_file = Path.cwd() / "identity.yml"
    if identity_file.exists():
        try:
            with open(identity_file) as f:
                data = yaml.safe_load(f)
            if data and "role" in data:
                return data["role"].lower()
        except Exception:
            pass

    return None


def is_file_allowed(file_path: str, project_root: Path) -> bool:
    """
    Check if the file path matches any allowed pattern for PM.

    Args:
        file_path: Absolute or relative path to the file
        project_root: Project root directory

    Returns:
        True if PM is allowed to edit this file
    """
    # Convert to absolute path if relative
    path = Path(file_path)
    if not path.is_absolute():
        path = Path.cwd() / path

    # Resolve symlinks for consistent path comparison (handles /tmp vs /private/tmp on macOS)
    try:
        path = path.resolve()
        project_root = project_root.resolve()
    except OSError:
        pass

    # Get path relative to project root
    try:
        rel_path = path.relative_to(project_root)
    except ValueError:
        # File is outside project root - not allowed
        return False

    rel_str = str(rel_path)

    # Check against allowed patterns
    for pattern in PM_ALLOWED_PATTERNS:
        if fnmatch.fnmatch(rel_str, pattern):
            return True

    return False


def main():
    try:
        # Read hook input from stdin
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        # No input or invalid JSON - allow tool to proceed
        print(json.dumps({"continue": True}))
        return 0

    # Get the file path being edited/written
    tool_input = hook_input.get("tool_input", {}) or hook_input.get("toolInput", {})
    file_path = tool_input.get("file_path", "") or tool_input.get("path", "")

    if not file_path:
        # No file path in input - allow
        print(json.dumps({"continue": True}))
        return 0

    # Check if current agent is PM
    role = get_agent_role(file_path)

    if role != "pm":
        # Not PM agent - allow all file operations
        print(json.dumps({"continue": True}))
        return 0

    # Find project root (search from file's directory, not CWD)
    project_root = find_project_root(file_path)

    if not project_root:
        # No project root found from file path - PM shouldn't be editing
        # files outside any workflow project
        output = {
            "decision": "block",
            "reason": f"""🚫 PM FILE ACCESS DENIED

You are the Project Manager (PM). You are NOT allowed to edit this file:
  {file_path}

This file is outside any workflow project. PM can only edit files within
a project that has a .workflow/ directory.

ACTION REQUIRED:
DELEGATE the work to an appropriate agent."""
        }
        print(json.dumps(output))
        return 0

    # Check if file is in allowed list
    if is_file_allowed(file_path, project_root):
        print(json.dumps({"continue": True}))
        return 0

    # File not allowed - block the tool use
    output = {
        "decision": "block",
        "reason": f"""🚫 PM FILE ACCESS DENIED

You are the Project Manager (PM). You are NOT allowed to edit this file:
  {file_path}

PM can ONLY edit workflow files:
  - .workflow/**/tasks.json (task management)
  - .workflow/**/prd.md (requirements)
  - .workflow/**/status.yml (workflow status)
  - .workflow/**/team.yml (team structure)
  - .workflow/**/agents/**/*.yml, *.md (agent configs)

ACTION REQUIRED:
Instead of editing this file yourself, DELEGATE the work to an appropriate agent:

  ${{CLAUDE_PLUGIN_ROOT}}/bin/send-message.sh <session>:<window> "Please [describe the change needed]"

Remember: PM coordinates and delegates. Agents implement."""
    }

    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
