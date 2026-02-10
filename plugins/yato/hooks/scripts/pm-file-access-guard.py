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
import sys
from pathlib import Path
from typing import Optional, Tuple


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


def find_project_root() -> Optional[Path]:
    """Find the project root by looking for .workflow/ directory."""
    current = Path.cwd()
    while current != current.parent:
        if (current / ".workflow").exists():
            return current
        current = current.parent
    return None


def get_agent_role() -> Optional[str]:
    """
    Determine the current agent's role.

    Checks:
    1. AGENT_ROLE environment variable (set by tmux or directly)
    2. Tmux session environment (if in tmux)
    3. identity.yml in current directory
    """
    # Check environment variable first
    # Note: If AGENT_ROLE is in environ but empty, that means "no role" (don't check tmux)
    if "AGENT_ROLE" in os.environ:
        role = os.environ["AGENT_ROLE"]
        if role:
            return role.lower()
        # Explicitly empty - return None without checking tmux
        return None

    # Try to get from tmux env (only if AGENT_ROLE not explicitly set)
    # Check if we're inside tmux
    if os.environ.get("TMUX"):
        try:
            import subprocess
            result = subprocess.run(
                ["tmux", "showenv", "AGENT_ROLE"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0 and "=" in result.stdout:
                role = result.stdout.strip().split("=", 1)[1]
                if role:
                    return role.lower()
        except Exception:
            pass

    # Check for identity.yml in current directory
    identity_file = Path.cwd() / "identity.yml"
    if identity_file.exists():
        try:
            import yaml
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
    role = get_agent_role()

    if role != "pm":
        # Not PM agent - allow all file operations
        print(json.dumps({"continue": True}))
        return 0

    # Find project root
    project_root = find_project_root()

    if not project_root:
        # No project root found - allow (might be outside workflow context)
        print(json.dumps({"continue": True}))
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

  ${CLAUDE_PLUGIN_ROOT}/bin/send-message.sh <session>:<window> "Please [describe the change needed]"

Remember: PM coordinates and delegates. Agents implement."""
    }

    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
