#!/usr/bin/env python3
"""
UserPromptSubmit hook that injects reminders into the PM's Claude context
when the user submits a prompt.

Only fires in the PM window. Non-PM windows and non-tmux sessions are ignored.

Loads suffixes from two levels:
1. Yato-level: USER_TO_PM_SUFFIX from config/defaults.conf
2. Workflow-level: user_to_pm_message_suffix from status.yml

Both are stacked (yato first, then workflow), separated by blank lines.
"""

import os
import sys
from pathlib import Path

import yaml

from role_detection import detect_role, find_project_root_from_cwd


def _load_config_get():
    """Load config.get via importlib (same pattern as other hook scripts)."""
    try:
        from lib.config import get as get_config
        return get_config
    except ImportError:
        import importlib.util
        yato_path = os.environ.get(
            "YATO_PATH", str(Path(__file__).resolve().parent.parent.parent)
        )
        cfg_path = os.path.join(yato_path, "lib", "config.py")
        spec = importlib.util.spec_from_file_location("config", cfg_path)
        cfg = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(cfg)
        return cfg.get


def _get_workflow_name():
    """Get workflow name from environment or tmux env."""
    import subprocess

    name = os.environ.get("WORKFLOW_NAME")
    if name:
        return name

    if os.environ.get("TMUX"):
        try:
            result = subprocess.run(
                ["tmux", "showenv", "WORKFLOW_NAME"],
                capture_output=True, text=True, timeout=2,
            )
            if result.returncode == 0 and "=" in result.stdout:
                name = result.stdout.strip().split("=", 1)[1]
                if name:
                    return name
        except Exception:
            pass

    return None


def find_workflow_path():
    """Find the current workflow path (same pattern as block-task-guard.py)."""
    project_root = find_project_root_from_cwd()
    if not project_root:
        return None

    workflow_dir = project_root / ".workflow"
    if not workflow_dir.exists():
        return None

    workflow_name = _get_workflow_name()
    if workflow_name:
        path = workflow_dir / workflow_name
        if path.exists():
            return path

    # Fallback: most recent numbered folder
    workflows = sorted(workflow_dir.glob("[0-9][0-9][0-9]-*"), reverse=True)
    if workflows and workflows[0].is_dir():
        return workflows[0]

    return None


def main():
    # Consume stdin (required for UserPromptSubmit hooks)
    sys.stdin.read()

    # Only fire in PM windows
    role = detect_role()
    if role != "pm":
        return 0

    # Load yato-level suffix
    get_config = _load_config_get()
    yato_suffix = get_config("USER_TO_PM_SUFFIX").strip()

    # Load workflow-level suffix
    workflow_suffix = ""
    workflow_path = find_workflow_path()
    if workflow_path:
        status_file = workflow_path / "status.yml"
        if status_file.exists():
            try:
                data = yaml.safe_load(status_file.read_text())
                if data and isinstance(data, dict):
                    workflow_suffix = str(data.get("user_to_pm_message_suffix", "")).strip()
            except Exception:
                pass

    # Stack: yato first, then workflow
    parts = []
    if yato_suffix:
        parts.append(yato_suffix)
    if workflow_suffix:
        parts.append(workflow_suffix)

    if not parts:
        return 0

    print("\n\n".join(parts))
    return 0


if __name__ == "__main__":
    sys.exit(main())
