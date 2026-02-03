#!/usr/bin/env python3
"""
Loop Stop Hook - Handles repeating loops via Claude Code's Stop hook.

This script is called by Claude Code when the agent finishes responding.
It checks for active loops in the current project and continues them by:
1. Reading input from stdin
2. Scanning .workflow/loops/ in the current project directory
3. Checking stop conditions
4. Sleeping for the interval
5. Returning {"decision": "block", "reason": prompt} to continue

Project isolation: The hook only looks at loops inside the current working
directory's .workflow/loops/ folder. Loops in other projects are never seen.

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

# Optional debug logging
DEBUG = os.environ.get("YATO_LOOP_DEBUG", "").lower() == "true"
LOG_FILE = Path.home() / ".yato" / "loop-stop-hook.log"

def debug_log(message):
    """Log debug messages to file if debugging enabled."""
    if DEBUG:
        LOG_FILE.parent.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(f"{message}\n")


def find_active_loop_in_project(project_path: Path):
    """Scan .workflow/loops/ in the project for an active loop.

    Returns (loop_folder, meta) tuple if found, (None, None) otherwise.
    """
    loops_dir = project_path / ".workflow" / "loops"
    if not loops_dir.exists():
        return None, None

    for d in sorted(loops_dir.iterdir()):
        if not d.is_dir():
            continue
        meta_file = d / "meta.json"
        if not meta_file.exists():
            continue
        try:
            with open(meta_file, "r") as f:
                meta = json.load(f)
            if meta.get("should_continue", False):
                return d, meta
        except (json.JSONDecodeError, IOError):
            continue

    return None, None


def main():
    debug_log(f"[START] loop-stop-hook invoked")

    # Read hook input from stdin (Claude Code provides session context)
    try:
        hook_input = json.load(sys.stdin)
        debug_log(f"[INPUT] Received: {json.dumps(hook_input)[:200]}")
    except (json.JSONDecodeError, EOFError):
        # No valid input, allow stop
        debug_log(f"[INPUT] No valid JSON input, allowing stop")
        return
    except Exception as e:
        # Any other error reading stdin, allow stop
        debug_log(f"[ERROR] Exception reading stdin: {e}")
        return

    # Prevent infinite loops: if Claude is already continuing due to a
    # previous stop hook invocation, don't block again
    if hook_input.get("stop_hook_active"):
        debug_log(f"[SKIP] stop_hook_active=true, preventing infinite loop")
        return

    # Use the project directory from Claude Code's hook input (cwd field).
    # This is the directory where Claude Code was started, giving natural
    # project isolation — we only see loops in .workflow/loops/ for this project.
    project_path = Path(hook_input.get("cwd") or os.getcwd())
    debug_log(f"[PROJECT] {project_path}")

    loop_folder, meta = find_active_loop_in_project(project_path)

    if not loop_folder or not meta:
        debug_log(f"[STOP] No active loops in {project_path / '.workflow' / 'loops'}")
        return

    debug_log(f"[FOUND] Active loop: {loop_folder.name}")

    manager = LoopManager(str(project_path))

    # meta was already loaded and validated by find_active_loop_in_project
    debug_log(f"[META] exec_count={meta.get('execution_count', 0)}")

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
