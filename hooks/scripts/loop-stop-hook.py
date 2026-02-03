#!/usr/bin/env python3
"""
Loop Stop Hook - Handles repeating loops via Claude Code's Stop hook.

This script is called by Claude Code when the agent finishes responding.
It checks for active loops and continues them by:
1. Reading input from stdin
2. Finding active loops from central registry (~/.yato/active-loops.json)
3. Checking stop conditions
4. Sleeping for the interval
5. Returning {"decision": "block", "reason": prompt} to continue

Exit codes:
- 0 with no JSON output: Allow Claude to stop
- 0 with decision JSON: Continue with the provided prompt
"""

import json
import sys
import time
from pathlib import Path

# Add lib to path for imports - use parent.parent to get to yato root
YATO_ROOT = Path(__file__).parent.parent.parent
sys.path.insert(0, str(YATO_ROOT))

# Import directly from loop_manager module (not via lib/__init__.py)
# to avoid transitive imports that require jinja2
import importlib.util
spec = importlib.util.spec_from_file_location("loop_manager", YATO_ROOT / "lib" / "loop_manager.py")
loop_manager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(loop_manager)
LoopManager = loop_manager.LoopManager
format_duration = loop_manager.format_duration
get_all_active_loops = loop_manager.get_all_active_loops
_unregister_loop = loop_manager._unregister_loop


def main():
    # Read hook input from stdin
    try:
        hook_input = json.load(sys.stdin)
    except json.JSONDecodeError:
        # No valid input, allow stop
        return

    # NOTE: We don't check stop_hook_active because our execution_count
    # mechanism prevents infinite loops. The stop_after_times/stop_after_seconds
    # conditions will terminate the loop properly.

    # Find all active loops from central registry (works regardless of cwd)
    active_loops = get_all_active_loops()

    if not active_loops:
        # No active loops anywhere, allow stop
        return

    # Use the first active loop (most common case: one active loop)
    loop_info = active_loops[0]
    loop_folder = Path(loop_info["folder"])

    # Get the project path for LoopManager
    project_path = loop_info.get("project_path")
    if not project_path:
        # Fallback: derive from loop_folder (parent of .workflow/loops/xxx)
        project_path = str(loop_folder.parent.parent.parent)

    manager = LoopManager(project_path)

    # Load fresh metadata
    meta = manager.load_meta(loop_folder)

    if not meta:
        # Invalid loop, allow stop
        return

    # Check if should_continue is false
    if not meta.get("should_continue", False):
        # Loop was cancelled, allow stop
        return

    # Check stop conditions BEFORE doing anything
    should_stop, reason = manager.check_stop_conditions(meta)

    if should_stop:
        # Stop conditions met, mark loop as stopped and allow stop
        manager.stop_loop(loop_folder, reason)
        # Output nothing to allow Claude to stop
        return

    # Get interval and prompt
    interval_seconds = meta.get("interval_seconds", 0)
    prompt = meta.get("prompt", "")

    if not prompt:
        # No prompt, allow stop
        return

    # Record this execution FIRST (so we know the execution count)
    meta = manager.record_execution(loop_folder)
    exec_count = meta.get("execution_count", 0)

    # Sleep for the interval ONLY if this is NOT the first execution
    # First execution should happen immediately, subsequent ones wait
    if interval_seconds > 0 and exec_count > 1:
        time.sleep(interval_seconds)

        # Re-check stop conditions AFTER sleeping (user might have cancelled during sleep)
        meta = manager.load_meta(loop_folder)
        if not meta.get("should_continue", False):
            # Loop was cancelled during sleep, allow stop
            return

        should_stop, reason = manager.check_stop_conditions(meta)
        if should_stop:
            manager.stop_loop(loop_folder, reason)
            return

    # Build status prefix to show loop state
    exec_count = meta.get("execution_count", 0)
    stop_times = meta.get("stop_after_times")
    stop_seconds = meta.get("stop_after_seconds")

    if stop_times:
        status = f"[Loop {exec_count}/{stop_times}]"
    elif stop_seconds:
        elapsed = meta.get("total_elapsed_seconds", 0)
        status = f"[Loop {exec_count}, {format_duration(elapsed)}/{format_duration(stop_seconds)}]"
    else:
        status = f"[Loop {exec_count}]"

    # Return decision to continue with the prompt
    output = {
        "decision": "block",
        "reason": f"{status} {prompt}"
    }

    print(json.dumps(output))


if __name__ == "__main__":
    main()
