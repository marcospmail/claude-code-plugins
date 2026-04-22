#!/usr/bin/env python3
"""
PreToolUse hook that prevents PM (or anyone) from marking tasks as completed
without running the Step 13 validation flow first.

Scope:
  Blocks Write/Edit/MultiEdit operations on any path matching
  ``**/.workflow/*/tasks.json``.

Rules:
  - If the tool's proposed write would make a task transition to
    ``status: completed`` (from anything other than ``completed``) while
    ``needs_validation`` is true (default true if missing) and ``validated``
    is false (default false if missing), the write is blocked.
  - If the proposed content is not valid JSON, the write is blocked with a
    parse error.
  - If the proposed content does not match the minimal schema
    (``{"tasks": [{"id": ..., "status": ...}, ...]}``), the write is blocked.
  - If ``status.yml`` in the sibling workflow directory has
    ``validate_tasks: false``, the guard is skipped entirely.
  - Allows un-completing a task (completed -> anything else).
  - Allows no-op writes (task already completed, unchanged).

On a block, the script exits with code 2 and prints a descriptive message
to stderr, per the Claude Code PreToolUse hook protocol.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional, Tuple

import yaml


SUPPORTED_TOOLS = {"Write", "Edit", "MultiEdit"}


def _exit_allow() -> int:
    """Allow the tool call to proceed."""
    print(json.dumps({"continue": True}))
    return 0


def _exit_block(message: str) -> int:
    """Block the tool call with stderr message and exit code 2."""
    print(message, file=sys.stderr)
    return 2


def _is_tasks_json_path(file_path: str) -> bool:
    """
    Return True if file_path matches ``**/.workflow/<anything>/tasks.json``.
    """
    if not file_path:
        return False
    path = Path(file_path)
    if path.name != "tasks.json":
        return False
    parent = path.parent
    # parent must be <some workflow name>; parent.parent must be .workflow
    if parent.parent.name != ".workflow":
        return False
    return True


def _reconstruct_proposed_content(
    tool_name: str,
    tool_input: Dict[str, Any],
    file_path: Path,
) -> Tuple[Optional[str], Optional[str]]:
    """
    Reconstruct what the file's contents would look like after the tool call.

    Returns (proposed_content, allow_reason). If allow_reason is non-None,
    the caller should allow the tool call (e.g. Edit whose old_string is
    missing -- let the tool itself surface the error).
    """
    if tool_name == "Write":
        content = tool_input.get("content")
        if content is None:
            # Nothing to validate; let the tool handle it.
            return None, "no content field"
        return content, None

    # Edit / MultiEdit both need to read current file contents.
    if not file_path.exists():
        # Tool will error out on its own; allow.
        return None, "file does not exist for edit"

    try:
        current = file_path.read_text(encoding="utf-8")
    except OSError as exc:
        return None, f"cannot read current file: {exc}"

    if tool_name == "Edit":
        old_s = tool_input.get("old_string", "")
        new_s = tool_input.get("new_string", "")
        replace_all = tool_input.get("replace_all", False)
        if old_s == "":
            # Unusual -- allow tool to surface any error.
            return None, "empty old_string"
        if old_s not in current:
            # Tool itself will report mismatch; allow.
            return None, "old_string not found"
        if replace_all:
            proposed = current.replace(old_s, new_s)
        else:
            proposed = current.replace(old_s, new_s, 1)
        return proposed, None

    # MultiEdit
    edits = tool_input.get("edits", [])
    if not isinstance(edits, list):
        return None, "edits is not a list"
    proposed = current
    for edit in edits:
        if not isinstance(edit, dict):
            return None, "edit entry is not a dict"
        old_s = edit.get("old_string", "")
        new_s = edit.get("new_string", "")
        replace_all = edit.get("replace_all", False)
        if old_s == "":
            return None, "empty old_string in MultiEdit"
        if old_s not in proposed:
            return None, "old_string not found in MultiEdit"
        if replace_all:
            proposed = proposed.replace(old_s, new_s)
        else:
            proposed = proposed.replace(old_s, new_s, 1)
    return proposed, None


def _validate_schema(parsed: Any) -> Optional[str]:
    """
    Return an error message if schema is invalid, else None.

    Required shape::
        { "tasks": [ { "id": ..., "status": ... }, ... ] }
    """
    if not isinstance(parsed, dict):
        return "tasks.json must be a JSON object at the top level."
    tasks = parsed.get("tasks")
    if not isinstance(tasks, list):
        return 'tasks.json must contain a "tasks" array.'
    for idx, task in enumerate(tasks):
        if not isinstance(task, dict):
            return f"Task at index {idx} is not an object."
        if "id" not in task:
            return f'Task at index {idx} is missing required field "id".'
        if "status" not in task:
            task_id = task.get("id", "<unknown>")
            return f'Task "{task_id}" (index {idx}) is missing required field "status".'
    return None


def _should_validate(workflow_dir: Path) -> bool:
    """
    Return True if validate_tasks is on (default true). Returns False only
    if status.yml explicitly sets validate_tasks: false.
    """
    status_file = workflow_dir / "status.yml"
    if not status_file.exists():
        return True
    try:
        with open(status_file) as f:
            data = yaml.safe_load(f)
    except Exception:
        return True
    if not isinstance(data, dict):
        return True
    value = data.get("validate_tasks")
    if value is False:
        return False
    return True


def _load_current_tasks(file_path: Path) -> List[Dict[str, Any]]:
    """Load current on-disk tasks.json; return [] if missing or unparseable."""
    if not file_path.exists():
        return []
    try:
        data = json.loads(file_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    if not isinstance(data, dict):
        return []
    tasks = data.get("tasks")
    if not isinstance(tasks, list):
        return []
    return [t for t in tasks if isinstance(t, dict)]


def _compute_violations(
    old_tasks: List[Dict[str, Any]],
    new_tasks: List[Dict[str, Any]],
) -> List[str]:
    """Return IDs of tasks that illegally transition to completed."""
    old_by_id: Dict[Any, Dict[str, Any]] = {}
    for t in old_tasks:
        if "id" in t:
            old_by_id[t["id"]] = t

    violations: List[str] = []
    for t in new_tasks:
        now = t.get("status")
        if now != "completed":
            continue
        was = old_by_id.get(t.get("id"), {}).get("status")
        if was == "completed":
            # No-op: already completed, unchanged (or re-affirmed).
            continue
        # Strict bool handling to prevent string-typed bypass:
        # - needs_validation must be explicitly False to be disabled; anything
        #   else (missing, null, "false" string, 0, etc.) counts as True.
        # - validated must be explicitly True to count as validated; anything
        #   else (missing, null, "true" string, 1, etc.) counts as False.
        needs_raw = t.get("needs_validation", True)
        validated_raw = t.get("validated", False)
        needs = needs_raw is not False
        validated = validated_raw is True
        if needs and not validated:
            violations.append(str(t.get("id")))
    return violations


def _build_violation_message(ids: List[str]) -> str:
    id_list = ", ".join(ids)
    return (
        "BLOCKED: Cannot mark the following task(s) completed — "
        "needs_validation:true but validated:false.\n"
        f"Tasks: {id_list}\n"
        "Follow the Step 13 validation flow in your briefing:\n"
        "  1. Read the agent's agent-tasks.md work report for each task.\n"
        "  2. Verify the files listed in the work report.\n"
        "  3. Set validated:true in tasks.json in the SAME write as status:completed.\n"
        "If you genuinely don't want to validate this task, set "
        "needs_validation:false first (in a separate edit)."
    )


def main() -> int:
    try:
        hook_input = json.loads(sys.stdin.read())
    except (json.JSONDecodeError, ValueError):
        # No / invalid stdin -- safe default: allow.
        return _exit_allow()

    tool_name = hook_input.get("tool_name") or hook_input.get("toolName") or ""
    if tool_name not in SUPPORTED_TOOLS:
        return _exit_allow()

    tool_input = hook_input.get("tool_input") or hook_input.get("toolInput") or {}
    file_path_str = tool_input.get("file_path") or tool_input.get("path") or ""

    if not _is_tasks_json_path(file_path_str):
        return _exit_allow()

    file_path = Path(file_path_str)
    workflow_dir = file_path.parent

    proposed, allow_reason = _reconstruct_proposed_content(
        tool_name, tool_input, file_path
    )
    if allow_reason is not None:
        # Reconstruction couldn't safely produce content -- let the tool run
        # and surface any errors itself.
        return _exit_allow()

    # Parse proposed JSON.
    try:
        parsed = json.loads(proposed)
    except json.JSONDecodeError as exc:
        return _exit_block(
            "BLOCKED: tasks.json would be invalid JSON after this write.\n"
            f"{exc}\n"
            "Fix the syntax and retry."
        )

    # Schema validation.
    schema_error = _validate_schema(parsed)
    if schema_error:
        return _exit_block(
            "BLOCKED: tasks.json schema violation after this write.\n"
            f"{schema_error}\n"
            'Every task must have both "id" and "status" fields.'
        )

    # Skip the validation check entirely if status.yml opts out.
    if not _should_validate(workflow_dir):
        return _exit_allow()

    new_tasks = parsed["tasks"]
    old_tasks = _load_current_tasks(file_path)
    violations = _compute_violations(old_tasks, new_tasks)
    if violations:
        return _exit_block(_build_violation_message(violations))

    return _exit_allow()


if __name__ == "__main__":
    sys.exit(main())
