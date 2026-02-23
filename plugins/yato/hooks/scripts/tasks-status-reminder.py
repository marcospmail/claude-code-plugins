#!/usr/bin/env python3
"""
PreToolUse hook that injects a reminder when PM edits tasks.json.
Prevents marking blocked tasks as "completed" - blocked stays blocked until resolved.
"""
import json
import sys
import os

def main():
    try:
        # Read hook input from stdin
        hook_input = json.loads(sys.stdin.read())
    except json.JSONDecodeError:
        # No input or invalid JSON - allow tool to proceed
        print(json.dumps({"continue": True}))
        return 0

    # Get the file path being edited
    tool_input = hook_input.get("toolInput", {})
    file_path = tool_input.get("file_path", "") or tool_input.get("path", "")

    # Only inject reminder for tasks.json edits
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
    else:
        output = {"continue": True}

    print(json.dumps(output))
    return 0

if __name__ == "__main__":
    sys.exit(main())
