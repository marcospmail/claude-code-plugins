#!/usr/bin/env python3
# /// script
# requires-python = ">=3.10"
# dependencies = [
#     "pyyaml>=6.0",
#     "jinja2>=3.1",
# ]
# ///
"""
Agent Manager - Create and manage Claude agents.

This module replaces the bash scripts:
- create-agent.sh
- init-agent-files.sh
- create-team.sh (partially)

Provides functions for:
- Creating agent files (identity, instructions, etc.)
- Creating tmux windows for agents
- Registering agents in agents.yml
- Sending briefings to agents
"""

import glob as globmod
import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional, List, Dict, Any

# Ensure yato venv site-packages are available when running from outside the project
_script_dir = Path(__file__).resolve().parent
_project_root = _script_dir.parent
_venv_site = globmod.glob(str(_project_root / ".venv" / "lib" / "python*" / "site-packages"))
if _venv_site and _venv_site[0] not in sys.path:
    sys.path.insert(0, _venv_site[0])

import yaml
from jinja2 import Environment, FileSystemLoader

# Handle imports for both `uv run` and direct script execution
try:
    from lib.workflow_ops import WorkflowOps
    from lib.tmux_utils import send_message, _tmux_cmd
except ModuleNotFoundError:
    # Running as script, add parent directory to path
    sys.path.insert(0, str(_project_root))
    from lib.workflow_ops import WorkflowOps
    from lib.tmux_utils import send_message, _tmux_cmd


class AgentManager:
    """
    Manages agent creation and lifecycle.

    Agents are stored in .workflow/<workflow>/agents/<name>/ with:
    - identity.yml
    - instructions.md
    - constraints.example.md
    - CLAUDE.md
    - agent-tasks.md
    """

    # Role configurations
    ROLE_CONFIGS = {
        "developer": {
            "can_modify_code": True,
            "purpose": "Implementation and development",
            "responsibilities": [
                "Implement features according to PRD and tasks.json",
                "Write clean, maintainable code",
                "Follow existing code patterns and conventions",
                "Update agent-tasks.md as you complete tasks",
                "Notify PM when tasks are done",
            ],
        },
        "backend-developer": {
            "can_modify_code": True,
            "purpose": "Backend implementation and development",
            "responsibilities": [
                "Implement backend features according to PRD",
                "Write clean, maintainable code",
                "Follow existing code patterns and conventions",
                "Update agent-tasks.md as you complete tasks",
                "Notify PM when tasks are done",
            ],
        },
        "frontend-developer": {
            "can_modify_code": True,
            "purpose": "Frontend implementation and development",
            "responsibilities": [
                "Implement frontend features according to PRD",
                "Write clean, maintainable code",
                "Follow existing code patterns and conventions",
                "Update agent-tasks.md as you complete tasks",
                "Notify PM when tasks are done",
            ],
        },
        "fullstack-developer": {
            "can_modify_code": True,
            "purpose": "Full-stack implementation and development",
            "responsibilities": [
                "Implement features across the stack",
                "Write clean, maintainable code",
                "Follow existing code patterns and conventions",
                "Update agent-tasks.md as you complete tasks",
                "Notify PM when tasks are done",
            ],
        },
        "qa": {
            "can_modify_code": "test-only",
            "purpose": "Testing and quality assurance",
            "responsibilities": [
                "Test implementations thoroughly",
                "Write and run test cases (you CAN create/modify test files in e2e/, tests/, __tests__/)",
                "Report bugs and issues to developers",
                "Verify fixes before marking complete",
                "Do NOT modify production code (src/, lib/, app/) - TEST FILES ONLY",
                "You are ALLOWED to use Write/Edit tools for test files",
            ],
        },
        "code-reviewer": {
            "can_modify_code": False,
            "purpose": "Code review and security analysis",
            "responsibilities": [
                "Review code for quality and best practices",
                "Check for security vulnerabilities",
                "Provide constructive feedback",
                "Request changes from developers - do NOT fix yourself",
                "Approve only when all issues are addressed",
            ],
        },
        "reviewer": {
            "can_modify_code": False,
            "purpose": "Code review",
            "responsibilities": [
                "Review code for quality and best practices",
                "Provide constructive feedback",
                "Request changes from developers - do NOT fix yourself",
                "Approve only when all issues are addressed",
            ],
        },
        "security-reviewer": {
            "can_modify_code": False,
            "purpose": "Security analysis",
            "responsibilities": [
                "Review code for security vulnerabilities",
                "Check for OWASP top 10 issues",
                "Provide security recommendations",
                "Request changes from developers",
            ],
        },
        "devops": {
            "can_modify_code": True,
            "purpose": "Infrastructure and deployment",
            "responsibilities": [
                "Manage infrastructure and deployment",
                "Set up CI/CD pipelines",
                "Monitor system health",
                "Handle environment configuration",
            ],
        },
        "designer": {
            "can_modify_code": False,
            "purpose": "Design and user experience",
            "responsibilities": [
                "Create and review designs",
                "Provide UX recommendations",
                "Work with developers on implementation",
                "Ensure design consistency",
            ],
        },
        "pm": {
            "can_modify_code": False,
            "purpose": "Project management and coordination",
            "responsibilities": [
                "Coordinate team and assign tasks",
                "Track progress in tasks.json",
                "Ensure quality standards are met",
                "Communicate with user for clarifications",
                "Verify all work is complete before marking done",
            ],
        },
    }

    def __init__(self, workflow_path: Optional[str] = None, yato_path: Optional[str] = None):
        """
        Initialize the agent manager.

        Args:
            workflow_path: Path to the workflow directory
            yato_path: Path to yato installation (for templates)
        """
        self.workflow_path = Path(workflow_path) if workflow_path else None
        self.yato_path = Path(yato_path) if yato_path else Path(
            os.environ.get("YATO_PATH", os.path.expanduser("~/dev/tools/yato"))
        )
        self.templates_dir = self.yato_path / "lib" / "templates"

        # Setup Jinja2 environment
        if self.templates_dir.exists():
            self.jinja_env = Environment(
                loader=FileSystemLoader(str(self.templates_dir)),
                keep_trailing_newline=True,
            )
        else:
            self.jinja_env = None

    # Default model per role
    ROLE_DEFAULT_MODELS = {
        "code-reviewer": "opus",
        "security-reviewer": "opus",
        "pm": "opus",
    }

    def _get_default_model(self, role: str) -> str:
        """Get the default model for a role."""
        return self.ROLE_DEFAULT_MODELS.get(role.lower(), "sonnet")

    def _get_role_config(self, role: str) -> Dict[str, Any]:
        """Get configuration for a role."""
        role_lower = role.lower()

        # Check exact match first
        if role_lower in self.ROLE_CONFIGS:
            return self.ROLE_CONFIGS[role_lower]

        # Check for partial matches
        if "developer" in role_lower or "dev" in role_lower:
            return {
                "can_modify_code": True,
                "purpose": "Development and implementation",
                "responsibilities": [
                    "Follow instructions from PM",
                    "Update agent-tasks.md as you work",
                    "Notify PM when blocked or done",
                ],
            }

        # Default config
        return {
            "can_modify_code": False,
            "purpose": "Support and analysis",
            "responsibilities": [
                "Follow instructions from PM",
                "Update agent-tasks.md as you work",
                "Notify PM when blocked or done",
            ],
        }

    def init_agent_files(
        self,
        project_path: str,
        agent_name: str,
        role: str,
        model: str = "sonnet",
        workflow_name: Optional[str] = None,
    ) -> Optional[str]:
        """
        Create agent configuration files (without tmux window).

        This creates the agent's directory with:
        - identity.yml (window field empty until tmux window created)
        - instructions.md
        - constraints.example.md
        - CLAUDE.md
        - agent-tasks.md

        Args:
            project_path: Path to the project root
            agent_name: Name for the agent
            role: Agent role (developer, qa, etc.)
            model: Model to use (haiku, sonnet, opus)
            workflow_name: Workflow name (auto-detected if not provided)

        Returns:
            Path to agent directory or None on failure
        """
        # Get workflow path
        if workflow_name is None:
            workflow_name = WorkflowOps.get_current_workflow(project_path)

        if not workflow_name:
            print("Error: No active workflow found")
            return None

        workflow_path = Path(project_path) / ".workflow" / workflow_name

        # Create agent directory
        agent_dir = workflow_path / "agents" / agent_name
        agent_dir.mkdir(parents=True, exist_ok=True)

        # Get role configuration
        role_config = self._get_role_config(role)
        can_modify_code = role_config["can_modify_code"]

        # Format can_modify_code for YAML
        if can_modify_code is True:
            can_modify_str = "true"
        elif can_modify_code == "test-only":
            can_modify_str = "test-only"
        else:
            can_modify_str = "false"

        # Create identity.yml
        identity_content = self._render_template("agent_identity.yml.j2", {
            "name": agent_name,
            "role": role,
            "model": model,
            "window": "",
            "session": "",
            "workflow_name": workflow_name,
            "can_modify_code": can_modify_str,
        })
        (agent_dir / "identity.yml").write_text(identity_content)

        # Build role description
        if can_modify_code is True:
            role_description = "You are responsible for writing and modifying code."
        elif can_modify_code == "test-only":
            role_description = (
                "You CAN write and modify TEST files (e2e/, tests/, __tests__/, *.spec.*, *.test.*).\n"
                "You CANNOT modify production code (src/, lib/, app/). Test files only!"
            )
        else:
            role_description = (
                "You review, test, or analyze code but do NOT modify it directly.\n"
                "Any changes must be requested from developers."
            )

        # Create instructions.md
        instructions_content = self._render_template("agent_instructions.md.j2", {
            "name_capitalized": agent_name.title(),
            "role_capitalized": role.replace("-", " ").title(),
            "agent_purpose": role_config["purpose"],
            "role_description": role_description,
            "responsibilities": "\n".join(f"- {r}" for r in role_config["responsibilities"]),
            "role": role,
        })
        (agent_dir / "instructions.md").write_text(instructions_content)

        # Create constraints.md
        if role == "pm":
            # PM gets specific constraints
            constraints_content = """# PM Constraints

## Forbidden Actions
- You CANNOT modify any code files
- Do NOT write implementation code
- Do NOT run tests directly (delegate to QA agent)
- Do NOT make git commits (delegate to agents)
- NEVER call cancel-checkin.sh - the check-in loop stops AUTOMATICALLY when all tasks are completed
  (only the USER can stop the loop early via /cancel-checkin if they choose to)

## Required Actions
- ALWAYS delegate implementation to agents
- ALWAYS update tasks.json when tasks change status
- ALWAYS provide specific, actionable feedback

## Communication Rules
- Keep messages concise and actionable
- Include acceptance criteria in task assignments
- Respond to agent check-ins promptly
"""
        else:
            # Other agents get customizable constraints
            constraints_content = """# Constraints

# Add project-specific constraints for this agent below.
# Examples:
# - Do NOT modify files in /config/
# - Do NOT make database schema changes
# - Do NOT use jQuery
"""
        (agent_dir / "constraints.md").write_text(constraints_content)

        # Create CLAUDE.md
        claude_content = self._render_template("agent_claude.md.j2", {
            "project_path": project_path,
            "workflow_name": workflow_name,
        })
        (agent_dir / "CLAUDE.md").write_text(claude_content)

        # Create agent-tasks.md
        tasks_content = self._render_template("agent_tasks.md.j2", {})
        (agent_dir / "agent-tasks.md").write_text(tasks_content)

        print(f"Created agent files for '{agent_name}' at: {agent_dir}")
        return str(agent_dir)

    def _render_template(self, template_name: str, context: Dict[str, Any]) -> str:
        """Render a Jinja2 template."""
        if self.jinja_env is None:
            raise RuntimeError(f"Templates directory not found: {self.templates_dir}")

        template = self.jinja_env.get_template(template_name)
        return template.render(**context)

    def _resolve_agent_name(self, role: str, name: Optional[str], project_path: Optional[str]) -> str:
        """
        Resolve the agent name, handling duplicates with smart numbering.

        When no custom name is given, uses the role as the name. If an agent
        with that name already exists in agents.yml, numbers them (qa-1, qa-2).

        Args:
            role: Agent role
            name: Custom name (if provided, used as-is)
            project_path: Project path for agents.yml lookup

        Returns:
            Resolved agent name (lowercase)
        """
        if name is not None:
            return name.lower()

        base_name = role.lower()

        # Check agents.yml for existing agents with same role
        if not project_path:
            return base_name

        workflow_path = WorkflowOps.get_current_workflow_path(project_path)
        if not workflow_path:
            return base_name

        agents_file = workflow_path / "agents.yml"
        if not agents_file.exists():
            return base_name

        try:
            with open(agents_file, "r") as f:
                data = yaml.safe_load(f)
        except Exception:
            return base_name

        if not data or "agents" not in data or not data["agents"]:
            return base_name

        existing_agents = data["agents"]

        # Count existing agents with same role
        same_role_agents = [a for a in existing_agents if a.get("role") == role]

        if not same_role_agents:
            # No existing agents of this role - use base name
            return base_name

        # There are existing agents with this role - we need to number
        # Check if the existing one was already numbered
        existing_names = [a.get("name", "") for a in same_role_agents]

        if len(same_role_agents) == 1 and existing_names[0] == base_name:
            # One existing agent with base name - rename it to -1 and use -2
            self._rename_agent(project_path, workflow_path, base_name, f"{base_name}-1", role)
            return f"{base_name}-2"

        # Multiple existing - find next number
        max_num = 0
        for a_name in existing_names:
            if a_name.startswith(f"{base_name}-"):
                try:
                    num = int(a_name[len(base_name) + 1:])
                    if num > max_num:
                        max_num = num
                except ValueError:
                    pass
            elif a_name == base_name:
                # Unnumbered existing - should have been renamed already
                pass

        return f"{base_name}-{max_num + 1}"

    def _rename_agent(self, project_path: str, workflow_path: Path, old_name: str, new_name: str, role: str) -> None:
        """Rename an agent in agents.yml and on disk."""
        # Update agents.yml
        agents_file = workflow_path / "agents.yml"
        if agents_file.exists():
            try:
                with open(agents_file, "r") as f:
                    data = yaml.safe_load(f)

                if data and "agents" in data and data["agents"]:
                    for agent in data["agents"]:
                        if agent.get("name") == old_name:
                            agent["name"] = new_name
                            break

                    WorkflowOps._write_agents_yml(agents_file, data)
            except Exception:
                pass

        # Rename agent directory
        old_dir = workflow_path / "agents" / old_name
        new_dir = workflow_path / "agents" / new_name
        if old_dir.exists() and not new_dir.exists():
            old_dir.rename(new_dir)
            # Update identity.yml name field
            identity_file = new_dir / "identity.yml"
            if identity_file.exists():
                content = identity_file.read_text()
                content = content.replace(f"name: {old_name}", f"name: {new_name}")
                identity_file.write_text(content)

    def create_agent(
        self,
        session: str,
        role: str,
        project_path: Optional[str] = None,
        name: Optional[str] = None,
        model: str = "sonnet",
        pm_window: Optional[str] = None,
        start_claude: bool = True,
        send_brief: bool = True,
    ) -> Optional[Dict[str, Any]]:
        """
        Create a new Claude agent in a tmux session.

        This:
        1. Creates a new tmux window (if session exists)
        2. Updates agent files with window info
        3. Registers agent in agents.yml
        4. Optionally starts Claude
        5. Optionally sends briefing

        If the tmux session doesn't exist, creates files and registry
        entries only (no tmux window, no Claude, no briefing).

        Args:
            session: Tmux session name
            role: Agent role
            project_path: Project path (working directory)
            name: Window name (defaults to role with smart numbering)
            model: Claude model (haiku, sonnet, opus)
            pm_window: PM window this agent reports to
            start_claude: Whether to start Claude automatically
            send_brief: Whether to send briefing message

        Returns:
            Agent info dict or None on failure
        """
        # Normalize role
        role = role.lower()

        # Expand project path
        if project_path:
            project_path = os.path.expanduser(project_path)
            if not os.path.isdir(project_path):
                print(f"Warning: Path '{project_path}' does not exist")

        # Resolve agent name with smart duplicate handling
        agent_name = self._resolve_agent_name(role, name, project_path)
        display_name = name if name else agent_name

        # Check session exists
        has_session = False
        result = subprocess.run(
            _tmux_cmd() + ["has-session", "-t", session],
            capture_output=True,
        )
        has_session = result.returncode == 0

        window_index = 0
        agent_id = f"{session}:0"

        if has_session:
            # Create agent window
            print(f"Creating window '{display_name}' in session '{session}'...")

            cmd = _tmux_cmd() + ["new-window", "-d", "-t", session, "-n", display_name, "-P", "-F", "#{window_index}"]
            if project_path:
                cmd.extend(["-c", project_path])

            result = subprocess.run(cmd, capture_output=True, text=True)
            if result.returncode != 0:
                print(f"Error: Failed to create window: {result.stderr}")
                return None

            window_index = int(result.stdout.strip())
            agent_id = f"{session}:{window_index}"
            print(f"Created window: {agent_id}")
        else:
            print(f"Session '{session}' not found - creating files and registry only (no tmux window)")

        # Get workflow info
        workflow_name = None
        workflow_path = None
        if project_path:
            workflow_name = WorkflowOps.get_current_workflow(project_path)
            if workflow_name:
                workflow_path = Path(project_path) / ".workflow" / workflow_name

        # Register in agents.yml
        if project_path and workflow_name:
            WorkflowOps.add_agent_to_yml(
                project_path, agent_name, role, window_index, model, session
            )

        # Update agent identity file with window info
        if workflow_path:
            agent_dir = workflow_path / "agents" / agent_name

            # Try by name first, then by role
            if not agent_dir.exists():
                agent_dir = workflow_path / "agents" / role

            identity_file = agent_dir / "identity.yml"
            if identity_file.exists():
                if has_session:
                    print("Updating existing agent files with window info...")
                    content = identity_file.read_text()
                    content = content.replace("window:", f"window: {window_index}")
                    content = content.replace("session:", f"session: {session}")
                    identity_file.write_text(content)
                    print(f"Updated identity file: {identity_file}")
            else:
                # Files don't exist - create them
                self.init_agent_files(project_path, agent_name, role, model, workflow_name)
                # Update with window info if we have a session
                if has_session:
                    identity_file = agent_dir / "identity.yml"
                    if identity_file.exists():
                        content = identity_file.read_text()
                        content = content.replace("window:", f"window: {window_index}")
                        content = content.replace("session:", f"session: {session}")
                        identity_file.write_text(content)

        # Start Claude (only if session exists)
        if start_claude and has_session:
            print("Starting Claude with bypass permissions...")
            claude_cmd = "claude --dangerously-skip-permissions"
            if model:
                claude_cmd += f" --model {model}"
                print(f"Using model: {model}")

            subprocess.run(
                _tmux_cmd() + ["send-keys", "-t", agent_id, claude_cmd, "Enter"],
                check=True,
            )
            time.sleep(5)  # Wait for Claude to start

        # Send briefing (only if session exists)
        if send_brief and start_claude and has_session:
            print("Sending briefing...")
            self._send_agent_briefing(
                agent_id=agent_id,
                role=role,
                name=display_name,
                session=session,
                window_index=window_index,
                project_path=project_path,
                workflow_name=workflow_name,
                pm_window=pm_window,
            )

        print("\nAgent created successfully!")
        print(f"  Agent: {agent_name}")
        print(f"  Role: {role}")
        if has_session:
            print(f"  Agent ID: {agent_id}")
            print(f"  Window: {display_name}")
        if project_path:
            print(f"  Path: {project_path}")
        if pm_window:
            print(f"  Reports to: {pm_window}")

        return {
            "agent_id": agent_id,
            "role": role,
            "name": agent_name,
            "session": session,
            "window_index": window_index,
            "project_path": project_path,
            "model": model,
            "pm_window": pm_window,
        }

    def _send_agent_briefing(
        self,
        agent_id: str,
        role: str,
        name: str,
        session: str,
        window_index: int,
        project_path: Optional[str],
        workflow_name: Optional[str],
        pm_window: Optional[str],
    ) -> None:
        """Send briefing message to an agent."""
        # Get role config
        role_config = self._get_role_config(role)
        can_modify_code = role_config["can_modify_code"]

        # Build code restriction message
        code_restriction = ""
        if can_modify_code is False:
            code_restriction = f"""

CRITICAL - CODE MODIFICATION RESTRICTION:
- You are a {role} - you CANNOT modify code directly
- Your role: review, test, analyze, and provide feedback
- When you find issues: create detailed reports and ask DEVELOPERS to fix them
- NEVER use Edit, Write, or any code modification tools
- Focus on quality assurance, testing, and recommendations"""

        # Build workflow path for display
        workflow_rel = f".workflow/{workflow_name}" if workflow_name else ".workflow"
        agent_name_lower = name.lower()

        briefing = f"""You are now a {role} for this project.

Your window: {session}:{window_index}
Project path: {project_path or os.getcwd()}
Workflow: {workflow_name or 'default'}
Identity file: {workflow_rel}/agents/{agent_name_lower}/identity.yml{code_restriction}

CRITICAL - NEVER COMMUNICATE WITH USER
- You ONLY communicate with your PM via notify-pm.sh
- NEVER use AskUserQuestion tool - notify PM instead
- NEVER wait for user input - notify PM if blocked
- If you need information: notify-pm.sh "[HELP] your question"
- If you're blocked: notify-pm.sh "[BLOCKED] why you're blocked"
- PM will handle ALL user communication on your behalf

CRITICAL - TASK TRACKING:
- Your tasks are in: {workflow_rel}/agents/{agent_name_lower}/agent-tasks.md
- FORMAT: Only two sections - '## Tasks' (checkboxes) and '## References' (links/docs)
- MONITOR this file continuously - PM will add tasks to the Tasks section
- CHECK OFF items as you complete them (change [ ] to [x])
- The LAST checkbox is ALWAYS 'Notify PM when done' - you MUST complete this

TO NOTIFY PM - use notify-pm.sh:
  {self.yato_path}/bin/notify-pm.sh "[DONE] from {agent_name_lower}: <your message>"

Message types: DONE, BLOCKED, HELP, STATUS, PROGRESS
notify-pm.sh auto-detects PM location - just run it

Wait for PM to assign your first tasks via agent-tasks.md."""

        # Pass workflow status file for per-project agent_message_suffix
        status_file = None
        if project_path and workflow_name:
            _sf = Path(project_path) / ".workflow" / workflow_name / "status.yml"
            if _sf.exists():
                status_file = str(_sf)

        send_message(agent_id, briefing, workflow_status_file=status_file)

    def create_team(
        self,
        session: str,
        agents: List[Dict[str, str]],
        project_path: Optional[str] = None,
    ) -> List[Dict[str, Any]]:
        """
        Create multiple agents from a team configuration.

        Args:
            session: Tmux session name
            agents: List of agent dicts with name, role, model keys
            project_path: Project path

        Returns:
            List of created agent info dicts
        """
        created = []
        for agent in agents:
            result = self.create_agent(
                session=session,
                role=agent.get("role", "developer"),
                project_path=project_path,
                name=agent.get("name"),
                model=agent.get("model", "sonnet"),
                pm_window=f"{session}:0.1",  # PM is always at window 0, pane 1
            )
            if result:
                created.append(result)

        return created


# ==================== Module-level functions ====================

def init_agent_files(
    project_path: str,
    agent_name: str,
    role: str,
    model: str = "sonnet",
) -> Optional[str]:
    """Create agent configuration files."""
    manager = AgentManager()
    return manager.init_agent_files(project_path, agent_name, role, model)


def create_agent(
    session: str,
    role: str,
    **kwargs,
) -> Optional[Dict[str, Any]]:
    """Create a new Claude agent."""
    manager = AgentManager()
    return manager.create_agent(session, role, **kwargs)


if __name__ == "__main__":
    import argparse

    parser = argparse.ArgumentParser(description="Agent manager for Yato")
    subparsers = parser.add_subparsers(dest="command", help="Commands")

    # init-files command
    init_parser = subparsers.add_parser("init-files", help="Create agent configuration files")
    init_parser.add_argument("agent_name", help="Agent name")
    init_parser.add_argument("role", help="Agent role")
    init_parser.add_argument("--project", "-p", default=".", help="Project path")
    init_parser.add_argument("--model", "-m", default="sonnet", help="Model")

    # create command
    create_parser = subparsers.add_parser("create", help="Create agent with tmux window")
    create_parser.add_argument("session", help="Tmux session name")
    create_parser.add_argument("role", help="Agent role")
    create_parser.add_argument("--project", "-p", help="Project path")
    create_parser.add_argument("--name", "-n", help="Window name")
    create_parser.add_argument("--model", "-m", default=None, help="Model (default: role-dependent)")
    create_parser.add_argument("--pm-window", help="PM window (session:window)")
    create_parser.add_argument("--no-start", action="store_true", help="Don't start Claude")
    create_parser.add_argument("--no-brief", action="store_true", help="Don't send briefing")

    args = parser.parse_args()

    if args.command == "init-files":
        init_agent_files(args.project, args.agent_name, args.role, args.model)

    elif args.command == "create":
        manager = AgentManager()
        model = args.model if args.model else manager._get_default_model(args.role)
        create_agent(
            session=args.session,
            role=args.role,
            project_path=args.project,
            name=args.name,
            model=model,
            pm_window=args.pm_window,
            start_claude=not args.no_start,
            send_brief=not args.no_brief,
        )

    else:
        parser.print_help()
