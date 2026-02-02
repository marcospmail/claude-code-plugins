#!/usr/bin/env python3
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

import os
import subprocess
import sys
import time
from pathlib import Path
from typing import Optional, List, Dict, Any

from jinja2 import Environment, FileSystemLoader

# Handle imports for both `uv run` and direct script execution
try:
    from lib.workflow_ops import WorkflowOps
    from lib.tmux_utils import send_message
except ModuleNotFoundError:
    # Running as script, add parent directory to path
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from lib.workflow_ops import WorkflowOps
    from lib.tmux_utils import send_message


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
        })
        (agent_dir / "instructions.md").write_text(instructions_content)

        # Create constraints.md (empty by default - user can customize)
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
        1. Creates a new tmux window
        2. Updates agent files with window info
        3. Registers agent in agents.yml
        4. Optionally starts Claude
        5. Optionally sends briefing

        Args:
            session: Tmux session name
            role: Agent role
            project_path: Project path (working directory)
            name: Window name (defaults to role capitalized)
            model: Claude model (haiku, sonnet, opus)
            pm_window: PM window this agent reports to
            start_claude: Whether to start Claude automatically
            send_brief: Whether to send briefing message

        Returns:
            Agent info dict or None on failure
        """
        # Normalize role
        role = role.lower()

        # Set default name
        if name is None:
            name = role.title()

        # Check session exists
        result = subprocess.run(
            ["tmux", "has-session", "-t", session],
            capture_output=True,
        )
        if result.returncode != 0:
            print(f"Error: Session '{session}' does not exist")
            print(f"Create it with: tmux new-session -d -s {session}")
            return None

        # Expand project path
        if project_path:
            project_path = os.path.expanduser(project_path)
            if not os.path.isdir(project_path):
                print(f"Warning: Path '{project_path}' does not exist")

        # Create agent window
        print(f"Creating window '{name}' in session '{session}'...")

        cmd = ["tmux", "new-window", "-t", session, "-n", name, "-P", "-F", "#{window_index}"]
        if project_path:
            cmd.extend(["-c", project_path])

        result = subprocess.run(cmd, capture_output=True, text=True)
        if result.returncode != 0:
            print(f"Error: Failed to create window: {result.stderr}")
            return None

        window_index = int(result.stdout.strip())
        agent_id = f"{session}:{window_index}"
        print(f"Created window: {agent_id}")

        # Get workflow info
        workflow_name = None
        workflow_path = None
        if project_path:
            workflow_name = WorkflowOps.get_current_workflow(project_path)
            if workflow_name:
                workflow_path = Path(project_path) / ".workflow" / workflow_name

        # Register in agents.yml
        if project_path and workflow_name:
            agent_name_lower = name.lower()
            WorkflowOps.add_agent_to_yml(
                project_path, agent_name_lower, role, window_index, model, session
            )

        # Update agent identity file with window info
        if workflow_path:
            agent_name_lower = name.lower()
            agent_dir = workflow_path / "agents" / agent_name_lower

            # Try by name first, then by role
            if not agent_dir.exists():
                agent_dir = workflow_path / "agents" / role

            identity_file = agent_dir / "identity.yml"
            if identity_file.exists():
                print("Updating existing agent files with window info...")
                content = identity_file.read_text()
                content = content.replace("window:", f"window: {window_index}")
                content = content.replace("session:", f"session: {session}")
                identity_file.write_text(content)
                print(f"Updated identity file: {identity_file}")
            else:
                # Files don't exist - create them
                self.init_agent_files(project_path, agent_name_lower, role, model, workflow_name)
                # Update with window info
                identity_file = agent_dir / "identity.yml"
                if identity_file.exists():
                    content = identity_file.read_text()
                    content = content.replace("window:", f"window: {window_index}")
                    content = content.replace("session:", f"session: {session}")
                    identity_file.write_text(content)

        # Start Claude
        if start_claude:
            print("Starting Claude with bypass permissions...")
            claude_cmd = "claude --dangerously-skip-permissions"
            if model:
                claude_cmd += f" --model {model}"
                print(f"Using model: {model}")

            subprocess.run(
                ["tmux", "send-keys", "-t", agent_id, claude_cmd, "Enter"],
                check=True,
            )
            time.sleep(5)  # Wait for Claude to start

        # Send briefing
        if send_brief and start_claude:
            print("Sending briefing...")
            self._send_agent_briefing(
                agent_id=agent_id,
                role=role,
                name=name,
                session=session,
                window_index=window_index,
                project_path=project_path,
                workflow_name=workflow_name,
                pm_window=pm_window,
            )

        print("\nAgent created successfully!")
        print(f"  Agent ID: {agent_id}")
        print(f"  Role: {role}")
        print(f"  Window: {name}")
        if project_path:
            print(f"  Path: {project_path}")
        if pm_window:
            print(f"  Reports to: {pm_window}")

        return {
            "agent_id": agent_id,
            "role": role,
            "name": name,
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

        send_message(agent_id, briefing)

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
    create_parser.add_argument("--model", "-m", default="sonnet", help="Model")
    create_parser.add_argument("--pm-window", help="PM window (session:window)")
    create_parser.add_argument("--no-start", action="store_true", help="Don't start Claude")
    create_parser.add_argument("--no-brief", action="store_true", help="Don't send briefing")

    args = parser.parse_args()

    if args.command == "init-files":
        init_agent_files(args.project, args.agent_name, args.role, args.model)

    elif args.command == "create":
        create_agent(
            session=args.session,
            role=args.role,
            project_path=args.project,
            name=args.name,
            model=args.model,
            pm_window=args.pm_window,
            start_claude=not args.no_start,
            send_brief=not args.no_brief,
        )

    else:
        parser.print_help()
