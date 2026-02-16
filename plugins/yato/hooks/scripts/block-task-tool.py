#!/usr/bin/env python3
"""
PreToolUse hook that blocks agents from using Claude Code's Task sub-agent tool.

Agents (PM, developer, QA) should communicate with teammates via tmux messages,
not by spawning sub-agents. When blocked, the message shows available tmux-based
agents from agents.yml and the send_message command syntax.
"""

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional


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
    if os.environ.get("TMUX"):
        try:
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


def get_agent_name() -> Optional[str]:
    """Get the current agent's name from AGENT_NAME env or tmux env."""
    if "AGENT_NAME" in os.environ:
        name = os.environ["AGENT_NAME"]
        if name:
            return name
        return None

    if os.environ.get("TMUX"):
        try:
            result = subprocess.run(
                ["tmux", "showenv", "AGENT_NAME"],
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


def find_workflow_path() -> Optional[Path]:
    """
    Find the current workflow path.

    Tries:
    1. WORKFLOW_NAME env var
    2. Tmux WORKFLOW_NAME env var
    3. Most recent numbered workflow folder (fallback)
    """
    project_root = find_project_root()
    if not project_root:
        return None

    workflow_dir = project_root / ".workflow"
    if not workflow_dir.exists():
        return None

    # Try WORKFLOW_NAME env var
    workflow_name = os.environ.get("WORKFLOW_NAME")
    if workflow_name:
        path = workflow_dir / workflow_name
        if path.exists():
            return path

    # Try tmux env
    if os.environ.get("TMUX"):
        try:
            result = subprocess.run(
                ["tmux", "showenv", "WORKFLOW_NAME"],
                capture_output=True,
                text=True,
                timeout=2,
            )
            if result.returncode == 0 and "=" in result.stdout:
                workflow_name = result.stdout.strip().split("=", 1)[1]
                if workflow_name:
                    path = workflow_dir / workflow_name
                    if path.exists():
                        return path
        except Exception:
            pass

    # Fallback: most recent numbered folder
    workflows = sorted(workflow_dir.glob("[0-9][0-9][0-9]-*"), reverse=True)
    if workflows and workflows[0].is_dir():
        return workflows[0]

    return None


def find_project_root() -> Optional[Path]:
    """Find the project root by looking for .workflow/ directory.

    Uses HOOK_CWD env var (set by hooks.json) to get the original working
    directory before uv run --directory changes CWD to the plugin directory.
    Falls back to Path.cwd() if HOOK_CWD is not set.
    """
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


def load_agents_from_yml(workflow_path: Path) -> List[Dict[str, Any]]:
    """
    Load all agents (PM + team) from agents.yml.

    Returns a list of dicts with keys: name, role, session, window, pane (optional)
    """
    agents_file = workflow_path / "agents.yml"
    if not agents_file.exists():
        return []

    try:
        import yaml
        with open(agents_file) as f:
            data = yaml.safe_load(f)
        if not data:
            return []
    except Exception:
        return []

    agents = []

    # Add PM
    pm_data = data.get("pm")
    if pm_data and isinstance(pm_data, dict):
        agents.append(pm_data)

    # Add team agents
    for entry in data.get("agents", []):
        if isinstance(entry, dict):
            agents.append(entry)

    return agents


def format_target(agent: Dict[str, Any]) -> str:
    """Format tmux target string from agent dict."""
    session = agent.get("session", "?")
    window = agent.get("window", "?")
    pane = agent.get("pane")
    if pane is not None:
        return f"{session}:{window}.{pane}"
    return f"{session}:{window}"


def build_block_message(role: str, agents: List[Dict[str, Any]], current_name: Optional[str]) -> str:
    """
    Build the block message with role-specific guidance.

    - PM: shown team agents (developer, qa, etc.) and told to delegate to them
    - Non-PM: shown only the PM agent and told to contact PM
    """
    is_pm = role == "pm"

    lines = [
        "TASK SUB-AGENT BLOCKED",
        "",
        f"You are a {role} agent. You cannot spawn sub-agents with the Task tool.",
    ]

    if is_pm:
        # PM sees team agents and is told to use /send-to-agent skill
        team_agents = [a for a in agents if a.get("role") != "pm"]

        if team_agents:
            lines.append("Instead, delegate work to your team agents using the /send-to-agent skill.")
            lines.append("")
            lines.append("Your team agents:")
            first_name = None
            for agent in team_agents:
                name = agent.get("name", "unknown")
                agent_role = agent.get("role", "unknown")
                if first_name is None:
                    first_name = name
                lines.append(f"  - {name} ({agent_role})")

            lines.append("")
            lines.append("Send a message with:")
            lines.append("  /send-to-agent <agent-name> \"message\"")

            if first_name:
                lines.append("")
                lines.append("Example:")
                lines.append(f"  /send-to-agent {first_name} \"Please implement the login feature\"")
        else:
            lines.append("")
            lines.append("No team agents found in agents.yml. Deploy agents first with the orchestrator.")
    else:
        # Non-PM agent sees only PM and is told to contact PM
        pm_agent = next((a for a in agents if a.get("role") == "pm"), None)

        if pm_agent:
            pm_target = format_target(pm_agent)
            lines.append("Instead, contact your PM to coordinate work.")
            lines.append("")
            lines.append(f"Your PM: pm at {pm_target}")
            lines.append("")
            lines.append("Send a message with:")
            lines.append(f"  cd ${{CLAUDE_PLUGIN_ROOT}} && uv run python lib/tmux_utils.py send {pm_target} \"message\"")
            lines.append("")
            lines.append("Example:")
            lines.append(f"  cd ${{CLAUDE_PLUGIN_ROOT}} && uv run python lib/tmux_utils.py send {pm_target} \"I need help with this task, can you assign another agent?\"")
        else:
            lines.append("")
            lines.append("No PM found in agents.yml. Contact the orchestrator for guidance.")

    return "\n".join(lines)


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        # Invalid JSON stdin - safe fallback, allow
        print(json.dumps({"continue": True}))
        return 0

    # Check if current agent has a role (PM, developer, QA, etc.)
    role = get_agent_role()

    if not role:
        # Not an agent (user/orchestrator) - allow Task tool
        print(json.dumps({"continue": True}))
        return 0

    # Agent detected - block Task tool
    current_name = get_agent_name()

    # Try to load teammates from agents.yml
    agents = []
    workflow_path = find_workflow_path()
    if workflow_path:
        agents = load_agents_from_yml(workflow_path)

    message = build_block_message(role, agents, current_name)

    output = {
        "decision": "block",
        "reason": message,
    }
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
