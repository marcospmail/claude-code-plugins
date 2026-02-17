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
import sys
from pathlib import Path
from typing import Optional

from role_detection import detect_role, find_project_root_from_cwd, find_project_root_from_path


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

    # Check if current agent is PM (via identity.yml scanning)
    # Try file path first, then fall back to CWD (file may be outside project)
    role = detect_role(file_path=file_path)
    if not role:
        role = detect_role()

    if role != "pm":
        # Not PM agent - allow all file operations
        print(json.dumps({"continue": True}))
        return 0

    # Find project root (search from file's directory, then fall back to CWD)
    project_root = find_project_root_from_path(file_path)
    if not project_root:
        project_root = find_project_root_from_cwd()

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
Instead of editing this file yourself, modify the tasks files and then delegate to the agents."""
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
Instead of editing this file yourself, modify the tasks files and then delegate to the agents.

Remember: PM coordinates and delegates. Agents implement."""
    }

    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
