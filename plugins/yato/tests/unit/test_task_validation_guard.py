"""Unit tests for hooks/scripts/task-validation-guard.py hook."""

from __future__ import annotations

import json
import os
import subprocess
import sys
from pathlib import Path
from typing import Any, Dict, List, Optional

import pytest
import yaml


HOOK_SCRIPT = os.path.join(
    os.path.dirname(__file__), "..", "..", "hooks", "scripts", "task-validation-guard.py"
)


def run_hook(hook_input: dict) -> subprocess.CompletedProcess:
    """Run the hook script with given input. Returns the CompletedProcess."""
    return subprocess.run(
        [sys.executable, HOOK_SCRIPT],
        input=json.dumps(hook_input),
        capture_output=True,
        text=True,
    )


def make_tasks_json(tasks: List[Dict[str, Any]]) -> str:
    """Serialize a list of tasks into tasks.json format."""
    return json.dumps({"tasks": tasks})


# ---------------------------------------------------------------------------
# Fixtures
# ---------------------------------------------------------------------------


@pytest.fixture
def workflow(tmp_path: Path) -> Path:
    """Create a temporary project with a .workflow/001-test directory."""
    wf = tmp_path / "project" / ".workflow" / "001-test"
    wf.mkdir(parents=True)
    return wf


@pytest.fixture
def tasks_path(workflow: Path) -> Path:
    """Path to tasks.json inside the workflow (file not yet created)."""
    return workflow / "tasks.json"


def write_tasks(tasks_path: Path, tasks: List[Dict[str, Any]]) -> None:
    tasks_path.write_text(make_tasks_json(tasks), encoding="utf-8")


def write_status(workflow: Path, data: Dict[str, Any]) -> None:
    (workflow / "status.yml").write_text(yaml.safe_dump(data), encoding="utf-8")


# ---------------------------------------------------------------------------
# Happy paths / allow cases
# ---------------------------------------------------------------------------


class TestAllowCases:
    def test_write_happy_path_completed_with_validated_true_allowed(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 1: Write transitions task to completed with validated:true → allowed."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": True},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"continue": True}

    def test_validate_tasks_false_in_status_yml_bypasses_guard(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 5: validate_tasks:false in status.yml → guard skipped, write allowed."""
        write_status(workflow, {"validate_tasks": False})
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": False},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"continue": True}

    def test_completed_to_in_progress_allowed(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 9: completed → in_progress (un-completing) is allowed."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": True},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "in_progress", "needs_validation": True, "validated": True},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"continue": True}

    def test_already_completed_unchanged_allowed(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 10: Task already completed, write leaves it unchanged → allowed."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": False},
            {"id": "T2", "status": "pending", "needs_validation": True, "validated": False},
        ])
        # Write the same tasks back (no-op for T1, T2 unchanged).
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": False},
            {"id": "T2", "status": "pending", "needs_validation": True, "validated": False},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"continue": True}

    def test_unsupported_tool_read_allowed_immediately(self) -> None:
        """Case 14: Unsupported tool (Read) → allowed immediately, no path check."""
        hook_input = {
            "tool_name": "Read",
            "tool_input": {"file_path": "/any/.workflow/foo/tasks.json"},
        }

        result = run_hook(hook_input)

        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"continue": True}

    def test_non_tasks_json_path_allowed(self, tmp_path: Path) -> None:
        """Write to a non-tasks.json path is not in scope → allowed."""
        other = tmp_path / "main.py"
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(other), "content": "print(1)"},
        }

        result = run_hook(hook_input)

        assert result.returncode == 0, result.stderr
        assert json.loads(result.stdout) == {"continue": True}


# ---------------------------------------------------------------------------
# Block cases
# ---------------------------------------------------------------------------


class TestBlockCases:
    def test_write_violation_needs_validation_true_validated_false_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 2: needs_validation:true, validated:false, status:completed → blocked."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": False},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T1" in result.stderr
        assert "needs_validation:true but validated:false" in result.stderr
        assert "Step 13" in result.stderr

    def test_edit_tool_violation_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 3: Edit tool flipping status to completed without validation → blocked."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
        ])
        # Edit: replace "pending" with "completed" (only one occurrence).
        hook_input = {
            "tool_name": "Edit",
            "tool_input": {
                "file_path": str(tasks_path),
                "old_string": '"status": "pending"',
                "new_string": '"status": "completed"',
            },
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T1" in result.stderr

    def test_multiedit_mixed_with_violation_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 4: MultiEdit with one valid edit and one violation → blocked."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
            {"id": "T2", "status": "pending", "needs_validation": True, "validated": False},
        ])
        hook_input = {
            "tool_name": "MultiEdit",
            "tool_input": {
                "file_path": str(tasks_path),
                "edits": [
                    # Edit 1: T1 → in_progress (benign).
                    {
                        "old_string": '{"id": "T1", "status": "pending", "needs_validation": true, "validated": false}',
                        "new_string": '{"id": "T1", "status": "in_progress", "needs_validation": true, "validated": false}',
                    },
                    # Edit 2: T2 → completed without validating (violation).
                    {
                        "old_string": '{"id": "T2", "status": "pending", "needs_validation": true, "validated": false}',
                        "new_string": '{"id": "T2", "status": "completed", "needs_validation": true, "validated": false}',
                    },
                ],
            },
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T2" in result.stderr

    def test_missing_needs_validation_defaults_to_true_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 6: Missing needs_validation defaults to true → blocked."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending"},
        ])
        new_content = make_tasks_json([
            # needs_validation missing; validated missing.
            {"id": "T1", "status": "completed"},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T1" in result.stderr

    def test_missing_task_id_schema_error(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 7: Task missing id → schema error, blocked."""
        write_tasks(tasks_path, [])
        new_content = make_tasks_json([
            {"status": "pending"},  # no id
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "schema" in result.stderr.lower()
        assert "id" in result.stderr.lower()

    def test_invalid_json_parse_error(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 8: Invalid JSON in proposed content → blocked with parse error."""
        write_tasks(tasks_path, [])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": "{not valid json"},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "invalid JSON" in result.stderr

    def test_new_task_added_as_completed_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 11: New task added directly with status:completed and no validation → blocked."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": True},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": True},
            # Freshly added T2, already marked completed without validation.
            {"id": "T2", "status": "completed", "needs_validation": True, "validated": False},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T2" in result.stderr

    def test_multiple_violations_reported_together(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 12: Multiple tasks violating → all ids listed in single error message."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
            {"id": "T2", "status": "pending", "needs_validation": True, "validated": False},
            {"id": "T3", "status": "pending", "needs_validation": True, "validated": False},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": False},
            {"id": "T2", "status": "completed", "needs_validation": True, "validated": False},
            {"id": "T3", "status": "completed", "needs_validation": True, "validated": True},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T1" in result.stderr
        assert "T2" in result.stderr
        # T3 had validated:true → not a violation, should not be in the blocked list.
        tasks_line = next(
            (line for line in result.stderr.splitlines() if line.startswith("Tasks:")),
            "",
        )
        assert "T1" in tasks_line and "T2" in tasks_line
        assert "T3" not in tasks_line

    def test_string_false_validated_still_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Case 13 (regression): validated as string "true" / "false" does not bypass guard.

        Strings are not the bool True, so validated is not considered true;
        strings are not the bool False for needs_validation, so it stays True.
        """
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
        ])
        # validated: "true" as string (not bool True) — should still block.
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": True, "validated": "true"},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T1" in result.stderr

    def test_string_false_needs_validation_still_blocked(
        self, workflow: Path, tasks_path: Path
    ) -> None:
        """Regression variant: needs_validation as string "false" must not bypass the guard."""
        write_tasks(tasks_path, [
            {"id": "T1", "status": "pending", "needs_validation": True, "validated": False},
        ])
        new_content = make_tasks_json([
            {"id": "T1", "status": "completed", "needs_validation": "false", "validated": False},
        ])
        hook_input = {
            "tool_name": "Write",
            "tool_input": {"file_path": str(tasks_path), "content": new_content},
        }

        result = run_hook(hook_input)

        assert result.returncode == 2
        assert "BLOCKED" in result.stderr
        assert "T1" in result.stderr
