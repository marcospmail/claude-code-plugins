---
name: loop
description: Start a repeating prompt loop that executes at intervals. Use for periodic tasks like checking logs, running tests, or monitoring status. Supports --times N (stop after N executions), --for DURATION (stop after time elapsed), or forever mode. Cancel with /loop --cancel.
allowed-tools: Bash, AskUserQuestion
user-invocable: true
context: fork
argument-hint: "[prompt] [--times N | --for DURATION | --forever] [--every INTERVAL]"
---

# Loop - Repeating Prompt Execution

<context>
This skill creates a repeating loop that executes a prompt at intervals using Claude Code's Stop hook mechanism. No background processes needed - the hook handles everything.

The loop continues until:
- `--times N`: After N executions
- `--for DURATION`: After the specified duration (e.g., 30m, 1h)
- `--forever`: Runs indefinitely until manually cancelled with `/loop --cancel`

Loops are stored in the project's `.workflow/loops/` directory.
</context>

<instructions>
## Parse Arguments

Parse the user's request to extract:
- **prompt**: What to execute repeatedly (required)
- **--times N**: Stop after N executions (mutually exclusive with --for)
- **--for DURATION**: Stop after duration like "30m", "1h" (mutually exclusive with --times)
- **--forever**: Run indefinitely until manually cancelled
- **--every INTERVAL**: Interval between executions like "5m", "30s" (optional, defaults to immediate)
- **--cancel**: Cancel the current loop instead of starting one

**IMPORTANT**: Cannot use both `--times` and `--for`. If none of `--times`, `--for`, or `--forever` is provided, use AskUserQuestion to let the user choose (see "Handle Missing Stop Condition" below).

## Handle Missing Stop Condition

If the user did NOT provide `--times`, `--for`, or `--forever`, use **AskUserQuestion** to ask:

**Question**: "How long should this loop run?"
**Options**:
1. **"Run N times"** — Ask follow-up for N, or default to a reasonable number
2. **"Run for a duration"** — Ask follow-up for duration (e.g., 30m, 1h)
3. **"Run forever"** — Loop runs indefinitely until cancelled with `/loop --cancel`

If the user selects "Run forever", proceed with no `--times` or `--for` flags (omit both from the command).

## Handle Cancel

If the user wants to cancel (includes --cancel or says "cancel", "stop"):

### Step 1: List running loops

⚠️ **YOU MUST INCLUDE `--project`** ⚠️ - Without it, loops will NOT be found.

Run this EXACT command - copy it character by character, do NOT simplify or remove any part:
```bash
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py list --status running --project "$PROJECT_DIR"
```

NEVER run `uv run python lib/loop_manager.py list` without `--project "$PROJECT_DIR"`. The `--project` flag is REQUIRED.

### Step 2: Handle results

- If no running loops found, output: "No active loops to cancel."
- If loops found, proceed to Step 3.

### Step 3: ALWAYS show AskUserQuestion for loop selection

⚠️ **MANDATORY**: You MUST use AskUserQuestion even if there is only ONE running loop. NEVER skip this step. NEVER auto-cancel without asking.

Use **AskUserQuestion** to let the user choose which loop to cancel:
- Show each running loop as an option (use the loop ID and first ~30 chars of prompt)
- Add "Cancel all loops" as the **last** option

### Step 4: Cancel the selected loop

Based on user selection, run the cancel command. MUST include `--project`:
```bash
# Cancel specific loop by ID
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py cancel --loop-id "LOOP_ID" --project "$PROJECT_DIR"

# Cancel all
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py cancel --all --project "$PROJECT_DIR"
```

### Step 5: Confirm

Output: "Loop cancelled." or "All loops cancelled."

## Start Loop

⚠️ **CRITICAL - YOU MUST CAPTURE PROJECT DIRECTORY FIRST** ⚠️

Before running the start command, you MUST run `PROJECT_DIR=$(pwd)` to capture the user's current directory.
The loop will be created in the wrong location without this.

**WRONG (loop created in wrong location):**
```bash
cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "prompt" --project "$(pwd)" ...
```

**CORRECT (loop created in user's project):**
```bash
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "prompt" --project "$PROJECT_DIR" ...
```

### Command Template

Run this pattern (do not modify the PROJECT_DIR capture):
```bash
# With stop condition (--times or --for)
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "PROMPT_HERE" \
  --session "$CLAUDE_CODE_SESSION_ID" \
  --project "$PROJECT_DIR" \
  --times N \  # OR --for "DURATION"
  --every "INTERVAL"  # Optional

# Forever mode (no --times or --for)
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "PROMPT_HERE" \
  --session "$CLAUDE_CODE_SESSION_ID" \
  --project "$PROJECT_DIR" \
  --every "INTERVAL"  # Optional
```

### Examples

```bash
# Run 3 times with no delay
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "check the logs for errors" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --times 3

# Run every 5 minutes for 30 minutes
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "run the test suite" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --for "30m" --every "5m"

# Run 5 times with 1 minute interval
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "check build status" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --times 5 --every "1m"

# Run forever every 10 minutes (cancel with /loop --cancel)
PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "check for new deployments" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --every "10m"
```

## Execute First Iteration Immediately

**CRITICAL**: After creating the loop, you MUST immediately execute the prompt yourself. Do NOT just output a confirmation message. The Stop hook will handle subsequent executions after you finish.

### Step 1: Brief confirmation
Output a SHORT confirmation (1-2 lines max):
```
Loop started (1/N): [prompt]
```

### Step 2: Execute the prompt NOW
Immediately perform what the user asked. For example:
- If prompt is "check weather", actually check the weather
- If prompt is "run tests", actually run the tests
- If prompt is "check logs for errors", actually check the logs

The Stop hook will:
1. See the loop is active when you finish
2. Wait for the interval (e.g., 1 minute)
3. Inject the next iteration prompt
4. Continue until stop conditions are met

### What NOT to do
- Do NOT just say "Loop started! The loop will execute via the Stop hook..."
- Do NOT wait for user input after creating the loop
- Do NOT output instructions about how to cancel - just execute the prompt
</instructions>

<examples>
<example>
<input>/loop check the logs for errors --times 3</input>
<action>
1. Extract: prompt="check the logs for errors", times=3, interval=immediate
2. Run: PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "check the logs for errors" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --times 3
3. Output: "Loop started (1/3): check the logs for errors"
4. IMMEDIATELY check the logs for errors (execute the prompt NOW)
</action>
</example>

<example>
<input>/loop run tests --every 5m --for 1h</input>
<action>
1. Extract: prompt="run tests", duration="1h", interval="5m"
2. Run: PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "run tests" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --for "1h" --every "5m"
3. Output: "Loop started (1/?): run tests"
4. IMMEDIATELY run the tests (execute the prompt NOW)
</action>
</example>

<example>
<input>/loop --cancel</input>
<action>
1. Detect cancel request
2. CRITICAL: List running loops with --project:
   PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py list --status running --project "$PROJECT_DIR"
3. If loops exist, use AskUserQuestion with options like:
   - "001-check-logs: check the logs for err..."
   - "002-run-tests: run the test suite..."
   - "Cancel all loops"
4. CRITICAL: Cancel with --project:
   PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py cancel --loop-id "LOOP_ID" --project "$PROJECT_DIR"
5. Confirm: "Loop cancelled."
</action>
</example>

<example>
<input>/loop monitor the build</input>
<action>
1. Missing stop condition (no --times, --for, or --forever)
2. Use AskUserQuestion: "How long should this loop run?"
   Options: "Run N times", "Run for a duration", "Run forever"
3. If user selects "Run forever":
   PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "monitor the build" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR"
4. If user selects "Run N times": ask for N, then run with --times N
5. If user selects "Run for a duration": ask for duration, then run with --for DURATION
6. Output: "Loop started (1/?): monitor the build"
7. IMMEDIATELY monitor the build (execute the prompt NOW)
</action>
</example>

<example>
<input>/loop check logs --forever --every 5m</input>
<action>
1. Extract: prompt="check logs", forever=true, interval="5m"
2. Run: PROJECT_DIR=$(pwd) && cd ${CLAUDE_PLUGIN_ROOT} && uv run python lib/loop_manager.py start "check logs" --session "$CLAUDE_CODE_SESSION_ID" --project "$PROJECT_DIR" --every "5m"
3. Output: "Loop started (1/?): check logs"
4. IMMEDIATELY check logs (execute the prompt NOW)
</action>
</example>
</examples>
