#!/usr/bin/env python3
"""
PreToolUse hook that blocks PM from using the SendMessage tool.

PM agents must use /send-to-agent to reach tmux-based agents. The built-in
SendMessage tool only works for in-process subagents, so messages to tmux
agents are silently lost.

Non-PM agents are not restricted.
"""

import json
import sys

from role_detection import detect_role


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        print(json.dumps({"continue": True}))
        return 0

    role = detect_role()

    if role != "pm":
        print(json.dumps({"continue": True}))
        return 0

    tool_input = hook_input.get("tool_input", {}) or hook_input.get("toolInput", {})
    recipient = tool_input.get("to", "")

    output = {
        "decision": "block",
        "reason": f"""PM SENDMESSAGE BLOCKED

You are the Project Manager (PM). The SendMessage tool CANNOT reach tmux-based agents.
SendMessage only works for in-process subagents — your team agents run in separate tmux windows.

Attempted recipient: {recipient}

ACTION REQUIRED:
Use /send-to-agent to communicate with team agents:
  /send-to-agent developer "Your message here"
  /send-to-agent qa "Your message here"

Agent names are listed in agents.yml.""",
    }
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
