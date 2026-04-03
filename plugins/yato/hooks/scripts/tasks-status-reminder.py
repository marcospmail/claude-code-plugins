#!/usr/bin/env python3
"""
PreToolUse hook that injects a reminder when PM edits tasks.json.
Prevents marking blocked tasks as "completed" - blocked stays blocked until resolved.
"""
import json
import sys
import os
from typing import Optional

import yaml


def _load_agent_description(agents_dir: str, role: str) -> Optional[str]:
    """Load description for a role from predefined agent YAML."""
    yml_path = os.path.join(agents_dir, f"{role}.yml")
    try:
        with open(yml_path, "r") as f:
            data = yaml.safe_load(f)
        return data.get("description")
    except (FileNotFoundError, yaml.YAMLError, AttributeError):
        return None


def get_agent_roster(file_path: str) -> Optional[str]:
    """Extract agent roster with descriptions from agents.yml and predefined agent YAMLs."""
    try:
        workflow_dir = os.path.dirname(file_path)
        agents_yml_path = os.path.join(workflow_dir, "agents.yml")

        with open(agents_yml_path, "r") as f:
            agents_data = yaml.safe_load(f)

        agents_list = agents_data["agents"]
        count = len(agents_list)

        # Load predefined agent descriptions
        yato_path = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        predefined_agents_dir = os.path.join(yato_path, "agents")

        agent_lines = []
        for agent in agents_list:
            name = agent["name"]
            role = agent.get("role", name)
            description = _load_agent_description(predefined_agents_dir, role)
            if description:
                agent_lines.append(f"- {name}: {description}")
            else:
                agent_lines.append(f"- {name}")

        roster_list = "\n".join(agent_lines)
        return (
            f"TEAM ROSTER ({count} agents):\n"
            f"{roster_list}\n\n"
            f"Assign tasks to all applicable agents. "
            f"When an agent's description mentions a mandatory skill/command, include it in the task instructions."
        )
    except (FileNotFoundError, KeyError, TypeError, yaml.YAMLError):
        return None


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        print(json.dumps({"continue": True}))
        return 0

    tool_input = hook_input.get("toolInput", {})
    file_path = tool_input.get("file_path", "") or tool_input.get("path", "")

    if "tasks.json" in file_path:
        output = {
            "continue": True,
            "systemMessage": """⚠️ PM RULES - READ CAREFULLY:

DELEGATION (YOU ARE PM, NOT A DEVELOPER):
• DELEGATE all implementation work to agents via /send-to-agent
• Do NOT write code, fix bugs, or implement features yourself
• Do NOT use Write/Edit tools on code files - only on workflow files (tasks.json, prd.md, agent-tasks.md)
• If work needs doing, assign it to an agent - that's your job as PM

TASK STATUS RULES:
• 'pending' = Not started yet
• 'in_progress' = Agent is working on it
• 'blocked' = Cannot proceed (stays blocked until resolved)
• 'completed' = Work was ACTUALLY PERFORMED by an agent and verified

CRITICAL:
1. NEVER mark 'completed' unless an agent ACTUALLY DID the work
2. Blocked tasks stay 'blocked' until resolved - you CANNOT skip tasks
3. If user says "skip it", task stays BLOCKED - do NOT mark as completed"""
        }

        roster = get_agent_roster(file_path)
        if roster:
            output["systemMessage"] += "\n\n" + roster
    else:
        output = {"continue": True}

    print(json.dumps(output))
    return 0

if __name__ == "__main__":
    sys.exit(main())
