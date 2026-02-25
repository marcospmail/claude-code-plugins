#!/usr/bin/env python3
"""
PreToolUse hook that restricts PM from running file-modifying Bash commands.

PM agents should delegate file modifications to team agents. This hook blocks
destructive/write commands while allowing everything else (read-only tools,
HTTP fetches, scripts, etc.).

Non-PM agents and users/orchestrators are not restricted.
"""

import json
import os
import re
import shlex
import sys
from typing import List, Optional, Tuple

from role_detection import detect_role


# Binaries PM is NOT allowed to use (file modification / destructive)
BLOCKED_BINARIES = {
    # File writers / editors
    "sed", "tee", "dd", "install",
    "vi", "vim", "nvim", "nano", "ed", "emacs",
    # File operations
    "cp", "mv", "rm", "mkdir", "touch", "chmod", "chown", "ln", "rmdir",
    "mktemp", "truncate", "shred",
    # Output commands that can write via redirects
    "echo", "printf", "cat",
    # Interpreters that can write files
    "python", "python3", "node", "ruby", "perl", "php",
    # Dangerous execution
    "eval", "exec",
    # Package managers
    "pip", "pip3", "npm", "npx", "yarn", "pnpm", "bun", "apt", "brew",
    "cargo", "go",
}

# Git write subcommands (read-only subcommands are allowed)
GIT_WRITE_SUBCOMMANDS = {
    "add", "commit", "push", "pull", "merge", "rebase", "reset", "checkout",
    "switch", "restore", "cherry-pick", "revert", "clean", "rm", "mv",
    "init", "clone", "fetch", "submodule", "bisect", "am", "apply",
}


def split_command_segments(command: str) -> List[str]:
    """Split a command into segments on &&, ||, ;, |. Respects quotes."""
    segments = []
    current = []
    i = 0
    in_single = False
    in_double = False

    while i < len(command):
        ch = command[i]

        if ch == "'" and not in_double:
            in_single = not in_single
            current.append(ch)
            i += 1
        elif ch == '"' and not in_single:
            in_double = not in_double
            current.append(ch)
            i += 1
        elif ch == "\\" and not in_single and i + 1 < len(command):
            current.append(ch)
            current.append(command[i + 1])
            i += 2
        elif not in_single and not in_double:
            if command[i : i + 2] in ("&&", "||"):
                seg = "".join(current).strip()
                if seg:
                    segments.append(seg)
                current = []
                i += 2
            elif ch in (";", "|"):
                seg = "".join(current).strip()
                if seg:
                    segments.append(seg)
                current = []
                i += 1
            else:
                current.append(ch)
                i += 1
        else:
            current.append(ch)
            i += 1

    seg = "".join(current).strip()
    if seg:
        segments.append(seg)

    return segments


def extract_subshells(command: str) -> List[str]:
    """Extract contents of $(...) and `...` subshells."""
    results = []

    # Extract $() subshells
    i = 0
    in_single = False
    in_double = False
    depth = 0
    start = -1
    while i < len(command):
        ch = command[i]
        if ch == "'" and not in_double and depth == 0:
            in_single = not in_single
            i += 1
        elif ch == '"' and not in_single:
            in_double = not in_double
            i += 1
        elif ch == "\\" and not in_single and i + 1 < len(command):
            i += 2
        elif not in_single:
            if command[i : i + 2] == "$(":
                if depth == 0:
                    start = i + 2
                depth += 1
                i += 2
            elif ch == ")" and depth > 0:
                depth -= 1
                if depth == 0 and start >= 0:
                    results.append(command[start:i])
                i += 1
            else:
                i += 1
        else:
            i += 1

    # Extract backtick subshells
    i = 0
    in_single = False
    bt_start = -1
    while i < len(command):
        ch = command[i]
        if ch == "'" and bt_start == -1:
            in_single = not in_single
            i += 1
        elif ch == "\\" and not in_single and i + 1 < len(command):
            i += 2
        elif ch == "`" and not in_single:
            if bt_start == -1:
                bt_start = i + 1
            else:
                results.append(command[bt_start:i])
                bt_start = -1
            i += 1
        else:
            i += 1

    return results


def extract_binary(tokens: List[str]) -> Tuple[str, str, List[str]]:
    """
    Extract the binary from tokens, skipping env var assignments.
    Returns (basename, full_path, remaining_tokens).
    """
    env_pat = re.compile(r"^[A-Za-z_][A-Za-z0-9_]*=")
    idx = 0
    while idx < len(tokens) and env_pat.match(tokens[idx]):
        idx += 1

    if idx >= len(tokens):
        return "", "", []

    full_path = tokens[idx]
    basename = os.path.basename(full_path)
    remaining = tokens[idx + 1 :] if idx + 1 < len(tokens) else []
    return basename, full_path, remaining


def validate_segment(segment: str) -> Optional[str]:
    """Validate a single command segment. Returns reason if blocked, None if allowed."""
    try:
        tokens = shlex.split(segment)
    except ValueError:
        return f"Cannot parse command: {segment[:80]}"

    if not tokens:
        return None

    binary, full_path, remaining = extract_binary(tokens)

    if not binary:
        return None  # Only env assignments

    # Check blocklist
    if binary in BLOCKED_BINARIES:
        return f"Binary '{binary}' is blocked for PM (file modification not allowed)"

    # Git: block write subcommands
    if binary == "git":
        # Skip flags before subcommand (e.g. git -C /path status)
        sub_idx = 0
        while sub_idx < len(remaining) and remaining[sub_idx].startswith("-"):
            if remaining[sub_idx] in ("-C", "-c", "--git-dir", "--work-tree"):
                sub_idx += 2
            else:
                sub_idx += 1
        subcommand = remaining[sub_idx] if sub_idx < len(remaining) else None
        if subcommand in GIT_WRITE_SUBCOMMANDS:
            return f"git subcommand '{subcommand}' is blocked for PM (write operation)"
        return None

    # Everything else is allowed
    return None


def validate_command(command: str) -> Optional[str]:
    """Validate a full command. Returns reason if blocked, None if allowed."""
    # Recursively validate subshell contents
    for sub in extract_subshells(command):
        reason = validate_command(sub)
        if reason:
            return f"Blocked in subshell: {reason}"

    # Validate each segment
    for segment in split_command_segments(command):
        reason = validate_segment(segment)
        if reason:
            return reason

    return None


def main():
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        print(json.dumps({"continue": True}))
        return 0

    tool_input = hook_input.get("tool_input", {}) or hook_input.get("toolInput", {})
    command = tool_input.get("command", "")

    if not command:
        print(json.dumps({"continue": True}))
        return 0

    role = detect_role()

    if role != "pm":
        print(json.dumps({"continue": True}))
        return 0

    # PM detected - validate against blocklist
    reason = validate_command(command)

    if reason is None:
        print(json.dumps({"continue": True}))
        return 0

    output = {
        "decision": "block",
        "reason": f"""PM BASH COMMAND BLOCKED

You are the Project Manager (PM). This Bash command is not allowed:
  {command[:200]}

Reason: {reason}

PM is blocked from running file-modifying commands:
  echo, printf, cat, sed, tee, cp, mv, rm, mkdir, touch, chmod
  python, python3, node, ruby, perl
  vi, vim, nano, ed
  git add, git commit, git push, git checkout, git reset
  pip, npm, brew, apt

Everything else is allowed (grep, ls, curl, jq, tmux, uv, scripts, etc.)

ACTION REQUIRED:
Delegate file modifications to your team agents using /send-to-agent.""",
    }
    print(json.dumps(output))
    return 0


if __name__ == "__main__":
    sys.exit(main())
