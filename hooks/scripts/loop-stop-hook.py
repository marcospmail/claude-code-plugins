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
import os

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

# Optional debug logging
DEBUG = os.environ.get("YATO_LOOP_DEBUG", "").lower() == "true"
LOG_FILE = Path.home() / ".yato" / "loop-stop-hook.log"

def debug_log(message):
    """Log debug messages to file if debugging enabled."""
    if DEBUG:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"{message}\n")


def main():
    debug_log(f"[START] loop-stop-hook invoked")

    # Read hook input from stdin
    try:
        hook_input = json.load(sys.stdin)
        debug_log(f"[INPUT] Received: {json.dumps(hook_input)[:100]}")
    except (json.JSONDecodeError, EOFError):
        # No valid input, allow stop
        debug_log(f"[INPUT] No valid JSON input, allowing stop")
        return
    except Exception as e:
        # Any other error reading stdin, allow stop
        debug_log(f"[ERROR] Exception reading stdin: {e}")
        return

    # NOTE: We don't check stop_hook_active because our execution_count
    # mechanism prevents infinite loops. The stop_after_times/stop_after_seconds
    # conditions will terminate the loop properly.

    # Determine the current project directory (Claude Code runs hooks in project cwd)
    # Resolve to real path to handle macOS /private/var vs /var symlinks
    current_project = str(Path(os.getcwd()).resolve())
    debug_log(f"[CWD] Current project: {current_project}")

    # Find all active loops from central registry
    all_active_loops = get_all_active_loops()
    debug_log(f"[LOOPS] Found {len(all_active_loops)} active loops globally")

    # Filter to only loops belonging to the current project
    active_loops = []
    for loop in all_active_loops:
        loop_project = loop.get("project_path", "")
        # Resolve both paths for comparison (handles symlinks like /private/var vs /var)
        try:
            resolved_loop_project = str(Path(loop_project).resolve())
        except (OSError, ValueError):
            resolved_loop_project = loop_project
        if resolved_loop_project == current_project:
            active_loops.append(loop)
        else:
            debug_log(f"[SKIP] Loop project '{resolved_loop_project}' != current '{current_project}'")

    debug_log(f"[LOOPS] {len(active_loops)} loops match current project")

    if not active_loops:
        # No active loops for this project, allow stop
        debug_log(f"[STOP] No active loops for current project, allowing stop")
        return

    # Use the first active loop for this project
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
    debug_log(f"[META] Loaded: exec_count={meta.get('execution_count', 0) if meta else 'N/A'}")

    if not meta:
        # Invalid loop, allow stop
        debug_log(f"[ERROR] Failed to load meta, allowing stop")
        return

    # Check if should_continue is false
    if not meta.get("should_continue", False):
        # Loop was cancelled, allow stop
        debug_log(f"[CANCEL] Loop cancelled, allowing stop")
        return

    # Check stop conditions BEFORE doing anything
    should_stop, reason = manager.check_stop_conditions(meta)
    debug_log(f"[CONDITIONS] should_stop={should_stop}, reason={reason}")

    if should_stop:
        # Stop conditions met, mark loop as stopped and allow stop
        manager.stop_loop(loop_folder, reason)
        debug_log(f"[STOP] Conditions met, stopping loop")
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

    debug_log(f"[OUTPUT] Continuing loop: {status}")
    print(json.dumps(output))


if __name__ == "__main__":
    main()
