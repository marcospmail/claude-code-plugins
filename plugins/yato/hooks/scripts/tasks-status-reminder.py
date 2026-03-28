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


def get_agent_roster(file_path: str) -> Optional[str]:
    """Extract agent roster from agents.yml in the same workflow directory as tasks.json."""
    try:
        workflow_dir = os.path.dirname(file_path)
        agents_yml_path = os.path.join(workflow_dir, "agents.yml")

        with open(agents_yml_path, "r") as f:
            agents_data = yaml.safe_load(f)

        agents_list = agents_data["agents"]
        agent_names = [agent["name"] for agent in agents_list]
        count = len(agent_names)
        names_str = ", ".join(agent_names)
        return f"TEAM ROSTER: Your team has {count} agents: {names_str}.\nAssign tasks to all applicable agents when creating or updating tasks."
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
