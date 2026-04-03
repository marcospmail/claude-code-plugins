#!/usr/bin/env python3
"""
Yato (Yet Another Tmux Orchestrator) - Main entry point for the orchestration system.

This module provides:
- Unified interface for all orchestration operations
- Project initialization and setup
- Team deployment and management
- High-level workflows
"""

import argparse
import json
import os
import re
import subprocess
import sys
from pathlib import Path
from typing import Optional, List, Dict

# Handle imports for both `uv run` and direct `python3 lib/orchestrator.py` execution
try:
    from lib.session_registry import Agent
    from lib.tmux_utils import TmuxOrchestrator as TmuxUtils, _tmux_cmd
    from lib.workflow_registry import WorkflowRegistry
except ModuleNotFoundError:
    # Running as script, add parent directory to path
    sys.path.insert(0, str(Path(__file__).parent.parent))
    from lib.session_registry import Agent
    from lib.tmux_utils import TmuxOrchestrator as TmuxUtils, _tmux_cmd
    from lib.workflow_registry import WorkflowRegistry


class Orchestrator:
    """
    Main orchestrator class for managing Claude agent teams.

    This class provides high-level operations for:
    - Creating and managing sessions
    - Deploying agent teams
    - Monitoring and coordination
    - Project lifecycle management
    """

    def __init__(self, project_root: Optional[Path] = None, project_path: Optional[str] = None, workflow_name: Optional[str] = None):
        """
        Initialize the orchestrator.

        Args:
            project_root: Path to the yato project root (for accessing bin/, lib/, templates/)
            project_path: Path to the target project (for workflow operations)
            workflow_name: Specific workflow name (optional, auto-detected if not provided)
        """
        self.project_root = project_root or Path(__file__).parent.parent
        self.bin_dir = self.project_root / "bin"
        self.lib_dir = self.project_root / "lib"
        self.templates_dir = self.project_root / "templates"

        self.tmux = TmuxUtils()
        self.tmux.safety_mode = False  # Disable confirmation prompts

        # Workflow context
        self._project_path = Path(project_path).expanduser().resolve() if project_path else None
        self._workflow_name = workflow_name
        self._registry = None

    def _get_registry(self, project_path: Optional[str] = None) -> Optional[WorkflowRegistry]:
        """Get or create a WorkflowRegistry for the given project path."""
        target_path = Path(project_path).expanduser().resolve() if project_path else self._project_path
        if not target_path:
            return None
        return WorkflowRegistry.from_project(target_path, self._workflow_name)

    def _register_agent_to_workflow(
        self,
        project_path: str,
        session_name: str,
        window_index: int,
        role: str,
        name: Optional[str] = None,
        model: Optional[str] = None,
        pane_id: Optional[str] = None
    ) -> Optional[Agent]:
        """Register an agent to the workflow's agents.yml file."""
        registry = self._get_registry(project_path)
        if not registry:
            return None

        agent = Agent(
            session_name=session_name,
            window_index=window_index,
            role=role,
            project_path=project_path,
            name=name or role,
            model=model,
            pane_id=pane_id
        )
        registry.add_agent(agent, is_pm=(role == "pm"))
        return agent

    # ==================== Session Management ====================

    def create_project_session(
        self,
        session_name: str,
        project_path: str,
        with_pm: bool = True,
        with_developer: bool = True
    ) -> Dict:
        """
        Create a new project session with standard agent setup.

        Args:
            session_name: Name for the tmux session
            project_path: Path to the project directory
            with_pm: Whether to create a PM agent
            with_developer: Whether to create a developer agent

        Returns:
            Dictionary with created session and agent info
        """
        result = {
            "session": session_name,
            "project_path": project_path,
            "agents": [],
            "directory_created": False
        }

        # Ensure project directory exists
        project_dir = Path(project_path).expanduser().resolve()
        if not project_dir.exists():
            project_dir.mkdir(parents=True, exist_ok=True)
            result["directory_created"] = True

        # Create session if it doesn't exist
        if not self.tmux.session_exists(session_name):
            if not self.tmux.create_session(session_name, project_path):
                result["error"] = f"Failed to create session: {session_name}"
                return result

        # Create PM if requested
        if with_pm:
            win_result = self.tmux.create_window(session_name, "Claude-PM", project_path)
            if win_result is not None:
                agent = self._register_agent_to_workflow(
                    project_path=project_path,
                    session_name=session_name,
                    window_index=win_result["window_index"],
                    role="pm",
                    name="PM",
                    pane_id=win_result["pane_id"]
                )
                if agent:
                    result["agents"].append(agent.to_dict())

        # Create developer if requested
        if with_developer:
            win_result = self.tmux.create_window(session_name, "Claude-Developer", project_path)
            if win_result is not None:
                agent = self._register_agent_to_workflow(
                    project_path=project_path,
                    session_name=session_name,
                    window_index=win_result["window_index"],
                    role="developer",
                    name="Developer",
                    pane_id=win_result["pane_id"]
                )
                if agent:
                    result["agents"].append(agent.to_dict())

        return result

    def deploy_team(
        self,
        session_name: str,
        project_path: str,
        team_config: List[Dict],
        project_context: Optional[Dict] = None,
        use_panes: bool = False
    ) -> Dict:
        """
        Deploy a team of agents with custom configuration.

        Args:
            session_name: Session name
            project_path: Project path
            team_config: List of agent configs with role, name, focus, skills, briefing
            project_context: Optional project context (PRD, tech stack, etc.)
            use_panes: If True, create all agents in panes within one window

        Example:
            team_config = [
                {"role": "pm", "focus": "Coordinate frontend and backend"},
                {"role": "developer", "name": "Frontend-Dev", "focus": "React UI", "skills": ["react", "css"]},
                {"role": "developer", "name": "Backend-Dev", "focus": "API endpoints", "skills": ["python", "fastapi"]},
                {"role": "qa", "name": "E2E-QA", "focus": "End-to-end testing"}
            ]
        """
        result = {
            "session": session_name,
            "project_path": project_path,
            "agents": [],
            "directory_created": False,
            "project_context": project_context,
            "use_panes": use_panes
        }

        # Ensure project directory exists
        project_dir = Path(project_path).expanduser().resolve()
        if not project_dir.exists():
            project_dir.mkdir(parents=True, exist_ok=True)
            result["directory_created"] = True

        # Create session
        if not self.tmux.session_exists(session_name):
            if not self.tmux.create_session(session_name, project_path):
                result["error"] = "Failed to create session"
                return result

        if use_panes:
            return self._deploy_team_panes(session_name, project_path, team_config, result)
        else:
            return self._deploy_team_windows(session_name, project_path, team_config, result)

    def deploy_pm_only(
        self,
        session_name: str,
        project_path: str,
        workflow_name: Optional[str] = None,
        is_existing_project: bool = False
    ) -> Dict:
        """
        Deploy only a PM agent in planning mode.

        The PM will:
        1. Ask discovery questions
        2. Generate PRD
        3. Propose team structure
        4. Wait for approval
        5. Deploy other agents

        Args:
            session_name: Name for the tmux session
            project_path: Path to the project directory
            workflow_name: Name of the workflow folder (e.g., "001-add-feature")

        Returns:
            Dictionary with created session and PM info
        """
        import subprocess

        result = {
            "session": session_name,
            "project_path": project_path,
            "workflow_name": workflow_name,
            "agents": [],
            "directory_created": False
        }

        # Ensure project directory exists
        project_dir = Path(project_path).expanduser().resolve()
        if not project_dir.exists():
            project_dir.mkdir(parents=True, exist_ok=True)
            result["directory_created"] = True

        # Create session
        if not self.tmux.session_exists(session_name):
            if not self.tmux.create_session(session_name, str(project_dir)):
                result["error"] = "Failed to create session"
                return result

        # Set WORKFLOW_NAME environment variable in the tmux session
        # This allows check-in scripts to know which workflow to use
        if workflow_name:
            subprocess.run(
                _tmux_cmd() + ["setenv", "-t", session_name,
                "WORKFLOW_NAME", workflow_name
            ], capture_output=True)

        # Rename window 0 to "Orchestrator"
        subprocess.run(_tmux_cmd() + ["rename-window", "-t", f"{session_name}:0", "Orchestrator"], capture_output=True)

        # Enable pane titles for future team members
        subprocess.run(_tmux_cmd() + ["set-option", "-t", session_name, "pane-border-status", "top"], capture_output=True)
        subprocess.run(_tmux_cmd() + ["set-option", "-t", session_name, "pane-border-format", " #{pane_title} "], capture_output=True)

        # Note: Check-ins are now stored per-workflow in .workflow/<workflow>/checkins.json
        # No global clearing needed - each workflow has its own checkins.json

        # Create layout: Check-ins (top) | PM (bottom)
        # Agents are created in separate windows, not panes
        checkin_display_script = self.bin_dir / "checkin-display.sh"

        # Split vertically for Check-ins on top (small pane)
        # -c ensures the new pane starts in project directory (needed for relative paths)
        # -l 10 gives 8-9 usable lines after accounting for pane border
        # The split pushes the original pane down; the new pane (check-ins) is on top.
        # We capture the pane_id of the original pane (PM) after the split.
        subprocess.run(_tmux_cmd() + [
            "split-window", "-t", f"{session_name}:0.0",
            "-v", "-b", "-l", "10",
            "-c", str(project_dir),
            "-P", "-F", "#{pane_id}"
        ], capture_output=True)
        # Now: pane 0 = Check-ins, pane 1 = PM

        # Capture PM pane_id (pane 1 after the split)
        pm_pane_id_result = subprocess.run(
            _tmux_cmd() + ["display-message", "-t", f"{session_name}:0.1", "-p", "#{pane_id}"],
            capture_output=True, text=True
        )
        pm_pane_id = pm_pane_id_result.stdout.strip() if pm_pane_id_result.returncode == 0 else None

        checkin_pane = f"{session_name}:0.0"
        pm_target = pm_pane_id or f"{session_name}:0.1"

        # Set up check-in status pane (uses relative paths from project directory)
        subprocess.run(_tmux_cmd() + ["select-pane", "-t", checkin_pane, "-T", "Check-ins"], capture_output=True)
        subprocess.run(_tmux_cmd() + ["set-option", "-p", "-t", checkin_pane, "allow-set-title", "off"], capture_output=True)

        # Wait for shell to be ready before sending commands
        import time
        time.sleep(0.5)

        # Start checkin-display.sh with explicit bash and absolute path for reliability
        subprocess.run(_tmux_cmd() + ["send-keys", "-t", checkin_pane, f"bash {checkin_display_script}", "Enter"], capture_output=True)

        # Set PM pane title and prevent programs from changing it
        subprocess.run(_tmux_cmd() + ["select-pane", "-t", pm_target, "-T", "PM"], capture_output=True)
        subprocess.run(_tmux_cmd() + ["set-option", "-p", "-t", pm_target, "allow-set-title", "off"], capture_output=True)

        # Create PM agent files (identity.yml, CLAUDE.md, agent-tasks.md, planning-briefing.md)
        # Always run init-files to ensure the full set of files is generated via Jinja2 templates
        if workflow_name:
            lib_dir = Path(__file__).parent
            init_cmd = [
                "uv", "run", "--directory", str(lib_dir.parent),
                "python", str(lib_dir / "agent_manager.py"),
                "init-files", "pm", "pm",
                "-p", str(project_dir), "-m", "opus",
                "-w", workflow_name,
            ]
            if is_existing_project:
                init_cmd.append("--existing")
            subprocess.run(init_cmd, capture_output=True)

        # Register PM agent - PM always uses Opus
        agent = self._register_agent_to_workflow(
            project_path=str(project_dir),
            session_name=session_name,
            window_index=0,
            role="pm",
            name="PM",
            model="opus",  # PM always uses Opus
            pane_id=pm_pane_id
        )
        if agent:
            result["agents"].append(agent.to_dict())
        result["pm_target"] = pm_target

        # Update PM identity.yml with pane_id and window info
        pm_identity = project_dir / ".workflow" / (workflow_name or "") / "agents" / "pm" / "identity.yml"
        if pm_identity.exists():
            content = pm_identity.read_text()
            content = re.sub(r'^(window:).*$', '\\1 0', content, flags=re.MULTILINE)
            if pm_pane_id:
                content = re.sub(r'^(pane_id:).*$', f'\\1 "{pm_pane_id}"', content, flags=re.MULTILINE)
            pm_identity.write_text(content)

        # Update status.yml with the correct session name (the workflow session,
        # not the invoking session where init-workflow.sh ran)
        status_file = project_dir / ".workflow" / (workflow_name or "") / "status.yml"
        if status_file.exists():
            content = status_file.read_text()
            content = re.sub(r'^(session:).*$', f'\\1 "{session_name}"', content, flags=re.MULTILINE)
            status_file.write_text(content)

        return result

    def start_pm_with_planning_briefing(self, pm_target: str, project_path: str) -> bool:
        """Start Claude in PM pane with planning briefing."""
        import subprocess
        import time

        # Determine yato path for bin/ references
        yato_path = os.environ.get("YATO_PATH", str(Path(__file__).resolve().parent.parent))

        # Start Claude with bypass permissions - PM always uses Opus
        model_flag = "--model opus"
        cmd = f"claude --dangerously-skip-permissions {model_flag} --effort medium"
        subprocess.run(_tmux_cmd() + ["send-keys", "-t", pm_target, cmd, "Enter"], check=True)

        # Wait for Claude to start fully
        time.sleep(6)

        # Create the briefing message - tells PM to read its agent files
        workflow_name = self._workflow_name or ""
        briefing = (
            f"You are the Project Manager for: {project_path}.\n\n"
            f"Read your agent files now. Start with your CLAUDE.md:\n"
            f"  .workflow/{workflow_name}/agents/pm/CLAUDE.md\n\n"
            f"It contains your role, instructions, and constraints inline.\n"
            f"Also read:\n"
            f"  1. identity.yml - who you are\n"
            f"  2. agent-tasks.md - current tasks\n"
            f"  3. planning-briefing.md - your complete planning workflow\n\n"
            f"After reading all files, begin the workflow in planning-briefing.md.\n"
            f"Start now: Read status.yml for the initial request, explore the codebase, then begin informed discovery!"
        )

        # Send briefing directly to PM pane (orchestrator knows the target)
        # skip_suffix because this is a system briefing, not an agent notification
        _wf_status = None
        if self._project_path and self._workflow_name:
            _sf = self._project_path / ".workflow" / self._workflow_name / "status.yml"
            if _sf.exists():
                _wf_status = str(_sf)
        self.tmux.send_message(pm_target, briefing, workflow_status_file=_wf_status, _skip_suffix=True)

        return True

    def _deploy_team_windows(
        self,
        session_name: str,
        project_path: str,
        team_config: List[Dict],
        result: Dict
    ) -> Dict:
        """Deploy team using separate windows (original behavior)."""
        # Find or create PM first
        for config in team_config:
            if config.get("role") == "pm":
                name = config.get("name", "Claude-PM")
                model = config.get("model") or self._get_default_model("pm")
                win_result = self.tmux.create_window(session_name, name, project_path)
                if win_result is not None:
                    agent = self._register_agent_to_workflow(
                        project_path=project_path,
                        session_name=session_name,
                        window_index=win_result["window_index"],
                        role="pm",
                        name=name,
                        model=model,
                        pane_id=win_result["pane_id"]
                    )
                    if agent:
                        result["agents"].append(agent.to_dict())
                break

        # Create other agents
        for config in team_config:
            role = config.get("role")
            if role == "pm":
                continue  # Already created

            name = config.get("name", f"Claude-{role.title()}")
            model = config.get("model") or self._get_default_model(role)
            win_result = self.tmux.create_window(session_name, name, project_path)
            if win_result is not None:
                agent = self._register_agent_to_workflow(
                    project_path=project_path,
                    session_name=session_name,
                    window_index=win_result["window_index"],
                    role=role,
                    name=name,
                    model=model,
                    pane_id=win_result["pane_id"]
                )
                if agent:
                    result["agents"].append(agent.to_dict())

        return result

    def _deploy_team_panes(
        self,
        session_name: str,
        project_path: str,
        team_config: List[Dict],
        result: Dict
    ) -> Dict:
        """Deploy team using panes within a single window.

        Layout: PM on left (full height), other agents stacked on right.
        """
        import subprocess

        # Rename window 0 to "Agents"
        subprocess.run(_tmux_cmd() + ["rename-window", "-t", f"{session_name}:0", "Agents"], capture_output=True)

        # Enable pane titles first
        subprocess.run(_tmux_cmd() + ["set-option", "-t", session_name, "pane-border-status", "top"], capture_output=True)
        subprocess.run(_tmux_cmd() + ["set-option", "-t", session_name, "pane-border-format", " #{pane_title} "], capture_output=True)

        # First pane is window 0, pane 0 - this will be the PM (left side)
        # Get the pane_id of pane 0
        pm_pane_result = subprocess.run(
            _tmux_cmd() + ["display-message", "-t", f"{session_name}:0.0", "-p", "#{pane_id}"],
            capture_output=True, text=True
        )
        pm_pane_id = pm_pane_result.stdout.strip() if pm_pane_result.returncode == 0 else f"{session_name}:0.0"
        pane_targets = [pm_pane_id]

        # Count non-PM agents
        other_agents = [c for c in team_config if c.get("role") != "pm"]

        if other_agents:
            # Create right side by splitting horizontally from PM pane
            # -h = horizontal split (creates pane to the right)
            cmd = _tmux_cmd() + ["split-window", "-h", "-t", pm_pane_id, "-P", "-F", "#{pane_id}"]
            if project_path:
                cmd.extend(["-c", project_path])
            result_split = subprocess.run(cmd, capture_output=True, text=True)

            if result_split.returncode == 0:
                right_pane = result_split.stdout.strip()
                pane_targets.append(right_pane)

                # Stack additional agents vertically on the right side
                for i in range(1, len(other_agents)):
                    # -v = vertical split (creates pane below)
                    cmd = _tmux_cmd() + ["split-window", "-v", "-t", right_pane, "-P", "-F", "#{pane_id}"]
                    if project_path:
                        cmd.extend(["-c", project_path])
                    result_split = subprocess.run(cmd, capture_output=True, text=True)
                    if result_split.returncode == 0:
                        pane_targets.append(result_split.stdout.strip())

        # Assign agents to panes
        pane_idx = 0

        # First pass: create PM
        for config in team_config:
            if config.get("role") == "pm":
                if pane_idx < len(pane_targets):
                    target = pane_targets[pane_idx]
                    name = config.get("name", "Claude-PM")
                    model = config.get("model") or self._get_default_model("pm")

                    # Set pane title
                    self.tmux.set_pane_title(target, name)

                    agent = self._register_agent_to_workflow(
                        project_path=project_path,
                        session_name=session_name,
                        window_index=0,
                        role="pm",
                        name=name,
                        model=model,
                        pane_id=target
                    )
                    if agent:
                        result["agents"].append(agent.to_dict())
                    pane_idx += 1
                break

        # Second pass: create other agents
        for config in team_config:
            role = config.get("role")
            if role == "pm":
                continue

            if pane_idx < len(pane_targets):
                target = pane_targets[pane_idx]
                name = config.get("name", f"Claude-{role.title()}")
                model = config.get("model") or self._get_default_model(role)

                # Set pane title
                self.tmux.set_pane_title(target, name)

                agent = self._register_agent_to_workflow(
                    project_path=project_path,
                    session_name=session_name,
                    window_index=0,
                    role=role,
                    name=name,
                    model=model,
                    pane_id=target
                )
                if agent:
                    result["agents"].append(agent.to_dict())
                pane_idx += 1

        return result

    def _get_default_model(self, role: str) -> str:
        """Get default Claude model based on agent role.

        Delegates to AgentManager which reads from agents/*.yml files.
        """
        from lib.agent_manager import AgentManager
        mgr = AgentManager(yato_path=str(self.project_root))
        return mgr._get_default_model(role)

    # ==================== Agent Operations ====================

    def start_claude_in_agents(self, project_path: str, agent_ids: Optional[List[str]] = None) -> Dict[str, bool]:
        """
        Start Claude in specified agents (or all registered agents).

        Uses --dangerously-skip-permissions and sets model based on agent config.

        Args:
            project_path: Path to the project
            agent_ids: List of agent IDs to start, or None for all

        Returns:
            Dictionary mapping agent_id to success status
        """
        registry = self._get_registry(project_path)
        if not registry:
            return {}

        if agent_ids is None:
            agents = registry.list_agents()
        else:
            agents = [registry.get_agent(aid) for aid in agent_ids if registry.get_agent(aid)]

        results = {}
        for agent in agents:
            if not agent:
                continue
            # Build Claude command with model, effort, and dangerous flag
            model = agent.model or "sonnet"
            claude_cmd = f"claude --dangerously-skip-permissions --model {model}"
            if agent.effort:
                claude_cmd += f" --effort {agent.effort}"

            success = self.tmux.send_message_to_agent(agent.agent_id, claude_cmd)
            results[agent.agent_id] = success

        return results

    def brief_agent(self, agent_id: str, message: str) -> bool:
        """Send a briefing message to an agent."""
        return self.tmux.send_message_to_agent(agent_id, message)

    def brief_team(self, project_path: str, message: str) -> Dict[str, bool]:
        """Send a message to all team members (non-PM agents)."""
        registry = self._get_registry(project_path)
        if not registry:
            return {}

        team = registry.get_team()
        results = {}
        for agent in team:
            results[agent.agent_id] = self.tmux.send_message_to_agent(agent.agent_id, message)
        return results

    def check_agent_status(self, agent_id: str, num_lines: int = 30) -> str:
        """Get recent output from an agent."""
        return self.tmux.capture_agent_output(agent_id, num_lines)

    # ==================== Monitoring ====================

    def get_system_status(self, project_path: Optional[str] = None) -> Dict:
        """Get comprehensive system status."""
        result = {
            "timestamp": __import__("datetime").datetime.now().isoformat(),
            "sessions": self.tmux.get_all_windows_status(),
            "agents": []
        }

        if project_path:
            registry = self._get_registry(project_path)
            if registry:
                result["workflow"] = registry.workflow_path.name
                result["agents"] = [a.to_dict() for a in registry.list_agents()]

        return result

    def create_snapshot(self) -> str:
        """Create a monitoring snapshot."""
        return self.tmux.create_monitoring_snapshot()



# ==================== CLI Interface ====================

def cmd_init(args: argparse.Namespace) -> int:
    """Initialize a new project session."""
    orchestrator = Orchestrator()
    result = orchestrator.create_project_session(
        session_name=args.session,
        project_path=args.path or os.getcwd(),
        with_pm=not args.no_pm,
        with_developer=not args.no_developer
    )

    if "error" in result:
        print(f"Error: {result['error']}")
        return 1

    print(f"Created session: {result['session']}")
    print(f"Project path: {result['project_path']}")
    if result.get("directory_created"):
        print(f"  (directory created)")
    print(f"Agents created: {len(result['agents'])}")
    for agent in result["agents"]:
        print(f"  - {agent['agent_id']} ({agent['role']})")

    return 0


def cmd_status(args: argparse.Namespace) -> int:
    """Show system status."""
    orchestrator = Orchestrator()

    if args.snapshot:
        print(orchestrator.create_snapshot())
    else:
        status = orchestrator.get_system_status()
        print(json.dumps(status, indent=2))

    return 0


def cmd_deploy(args: argparse.Namespace) -> int:
    """Deploy a team configuration."""
    orchestrator = Orchestrator()

    # Parse team config from JSON or use default
    project_context = None
    if args.config:
        with open(args.config) as f:
            config_data = json.load(f)

        # Handle both formats:
        # Old: [{"role": "pm"}, {"role": "developer"}]
        # New: {"project_context": {...}, "agents": [...]}
        if isinstance(config_data, list):
            team_config = config_data
        else:
            team_config = config_data.get("agents", [])
            project_context = config_data.get("project_context")
    else:
        # Default team: read from development.yml template
        from lib.agent_manager import AgentManager
        mgr = AgentManager(yato_path=str(Path(__file__).parent.parent))
        template_path = Path(__file__).parent.parent / "templates" / "team-suggestions" / "development.yml"
        template = mgr.load_team_template(str(template_path))
        if template and "agents" in template:
            team_config = [{"role": "pm"}] + template["agents"]
        else:
            # Fallback: PM + developer
            team_config = [
                {"role": "pm"},
                {"role": "developer"},
            ]

    result = orchestrator.deploy_team(
        session_name=args.session,
        project_path=args.path or os.getcwd(),
        team_config=team_config,
        project_context=project_context,
        use_panes=args.panes
    )

    if "error" in result:
        print(f"Error: {result['error']}")
        return 1

    print(f"Deployed team to: {result['session']}")
    if result.get("directory_created"):
        print(f"  (directory created)")
    for agent in result["agents"]:
        print(f"  - {agent['agent_id']} ({agent['role']})")

    return 0


def cmd_start(args: argparse.Namespace) -> int:
    """Start Claude in agents."""
    orchestrator = Orchestrator()

    agent_ids = args.agents if args.agents else None
    results = orchestrator.start_claude_in_agents(agent_ids)

    for agent_id, success in results.items():
        status = "started" if success else "failed"
        print(f"{agent_id}: {status}")

    return 0 if all(results.values()) else 1


def cmd_brief(args: argparse.Namespace) -> int:
    """Send a briefing to an agent or team."""
    orchestrator = Orchestrator()

    if args.team:
        results = orchestrator.brief_team(args.target, args.message)
        for agent_id, success in results.items():
            status = "sent" if success else "failed"
            print(f"{agent_id}: {status}")
        return 0 if all(results.values()) else 1
    else:
        success = orchestrator.brief_agent(args.target, args.message)
        print("Briefing sent" if success else "Failed to send briefing")
        return 0 if success else 1


def cmd_check(args: argparse.Namespace) -> int:
    """Check agent status/output."""
    orchestrator = Orchestrator()

    output = orchestrator.check_agent_status(args.agent, args.lines)
    print(output)

    return 0


def cmd_deploy_pm(args: argparse.Namespace) -> int:
    """Deploy only a PM in planning mode."""
    orchestrator = Orchestrator()

    project_path = args.path or os.getcwd()
    result = orchestrator.deploy_pm_only(
        session_name=args.session,
        project_path=project_path,
        workflow_name=args.workflow,
        is_existing_project=args.existing
    )

    if "error" in result:
        print(f"Error: {result['error']}")
        return 1

    print(f"Created session: {result['session']}")
    print(f"Project path: {result['project_path']}")
    if result.get("directory_created"):
        print(f"  (directory created)")
    print(f"PM deployed at: {result['pm_target']}")

    # Start Claude with planning briefing
    print("\nStarting PM with planning briefing...")
    orchestrator.start_pm_with_planning_briefing(result['pm_target'], project_path)

    print(f"\n✓ PM is ready! Attach with:")
    print(f"  tmux attach -t {args.session}")
    print(f"\nThe PM will ask you questions and propose a team structure.")

    return 0


def main():
    parser = argparse.ArgumentParser(
        description="Yato (Yet Another Tmux Orchestrator) - Manage Claude AI agent teams",
        formatter_class=argparse.RawDescriptionHelpFormatter
    )

    subparsers = parser.add_subparsers(dest="command", help="Available commands")

    # init command
    init_parser = subparsers.add_parser("init", help="Initialize a project session")
    init_parser.add_argument("session", help="Session name")
    init_parser.add_argument("-p", "--path", help="Project path (default: current directory)")
    init_parser.add_argument("--no-pm", action="store_true", help="Don't create PM agent")
    init_parser.add_argument("--no-developer", action="store_true", help="Don't create developer agent")

    # status command
    status_parser = subparsers.add_parser("status", help="Show system status")
    status_parser.add_argument("-s", "--snapshot", action="store_true", help="Show monitoring snapshot")

    # deploy command
    deploy_parser = subparsers.add_parser("deploy", help="Deploy a team")
    deploy_parser.add_argument("session", help="Session name")
    deploy_parser.add_argument("-p", "--path", help="Project path")
    deploy_parser.add_argument("-c", "--config", help="Team config JSON file")
    deploy_parser.add_argument("--panes", action="store_true", help="Use panes in single window instead of multiple windows")

    # deploy-pm command (planning mode) - PM always uses Opus
    deploy_pm_parser = subparsers.add_parser("deploy-pm", help="Deploy only PM in planning mode (uses Opus)")
    deploy_pm_parser.add_argument("session", help="Session name")
    deploy_pm_parser.add_argument("-p", "--path", help="Project path")
    deploy_pm_parser.add_argument("-w", "--workflow", help="Workflow name (e.g., 001-add-feature)")
    deploy_pm_parser.add_argument("--existing", action="store_true", help="Existing project (enables codebase exploration)")

    # start command
    start_parser = subparsers.add_parser("start", help="Start Claude in agents")
    start_parser.add_argument("agents", nargs="*", help="Agent IDs (empty for all)")

    # brief command
    brief_parser = subparsers.add_parser("brief", help="Send briefing to agent(s)")
    brief_parser.add_argument("target", help="Agent ID or PM ID (with --team)")
    brief_parser.add_argument("message", help="Message to send")
    brief_parser.add_argument("-t", "--team", action="store_true", help="Send to PM's team")

    # check command
    check_parser = subparsers.add_parser("check", help="Check agent output")
    check_parser.add_argument("agent", help="Agent ID")
    check_parser.add_argument("-n", "--lines", type=int, default=30, help="Lines to capture")

    args = parser.parse_args()

    if not args.command:
        parser.print_help()
        return 0

    cmd_map = {
        "init": cmd_init,
        "status": cmd_status,
        "deploy": cmd_deploy,
        "deploy-pm": cmd_deploy_pm,
        "start": cmd_start,
        "brief": cmd_brief,
        "check": cmd_check,
    }

    handler = cmd_map.get(args.command)
    if handler:
        return handler(args)
    else:
        print(f"Unknown command: {args.command}")
        return 1


if __name__ == "__main__":
    sys.exit(main())
