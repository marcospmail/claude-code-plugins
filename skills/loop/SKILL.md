---
name: loop
description: Start a repeating prompt loop that executes at intervals until a stop condition is met. Use for periodic tasks like checking logs, running tests, or monitoring status. Supports --times N (stop after N executions) or --for DURATION (stop after time elapsed). Cancel with /loop --cancel.
allowed-tools: Bash, AskUserQuestion
user-invocable: true
context: fork
argument-hint: "[prompt] --times N OR --for DURATION [--every INTERVAL]"
---

# Loop - Repeating Prompt Execution

<context>
This skill creates a repeating loop that executes a prompt at intervals using Claude Code's Stop hook mechanism. No background processes needed - the hook handles everything.

The loop continues until:
- `--times N`: After N executions
- `--for DURATION`: After the specified duration (e.g., 30m, 1h)

Loops are stored in the project's `.workflow/loops/` directory.
</context>

<instructions>
## Parse Arguments

Parse the user's request to extract:
- **prompt**: What to execute repeatedly (required)
- **--times N**: Stop after N executions (mutually exclusive with --for)
- **--for DURATION**: Stop after duration like "30m", "1h" (mutually exclusive with --times)
- **--every INTERVAL**: Interval between executions like "5m", "30s" (optional, defaults to immediate)
- **--cancel**: Cancel the current loop instead of starting one

**IMPORTANT**: Either `--times` or `--for` is REQUIRED. Cannot use both.

## Handle Cancel

If the user wants to cancel (includes --cancel or says "cancel", "stop"):

⚠️ **CRITICAL - YOU MUST CAPTURE PROJECT DIRECTORY FIRST** ⚠️

Before ANY command, you MUST run `PROJECT_DIR=$(pwd)` to capture the user's current directory.
Without this, the loop list/cancel commands will NOT find the loops.

**WRONG (will fail):**
```bash
cd ~/dev/tools/yato && uv run yato loop list --status running
```

**CORRECT (will work):**
```bash
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop list --status running --project "$PROJECT_DIR"
```

### Step 1: List running loops

Run this EXACT command (do not modify or simplify):
```bash
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop list --status running --project "$PROJECT_DIR"
```

### Step 2: Handle results

- If no running loops found, output: "No active loops to cancel."
- If loops found, proceed to Step 3.

### Step 3: Show AskUserQuestion for loop selection

Use **AskUserQuestion** to let the user choose which loop to cancel:
- Show each running loop as an option (use the loop ID and first ~30 chars of prompt)
- Add "Cancel all loops" as the **last** option

### Step 4: Cancel the selected loop

Based on user selection, run the appropriate cancel command:
```bash
# Cancel specific loop by ID (MUST include --project)
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop cancel --loop-id "LOOP_ID" --project "$PROJECT_DIR"

# Cancel all (MUST include --project)
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop cancel --all --project "$PROJECT_DIR"
```

### Step 5: Confirm

Output: "Loop cancelled." or "All loops cancelled."

## Start Loop

⚠️ **CRITICAL - YOU MUST CAPTURE PROJECT DIRECTORY FIRST** ⚠️

Before running the start command, you MUST run `PROJECT_DIR=$(pwd)` to capture the user's current directory.
The loop will be created in the wrong location without this.

**WRONG (loop created in wrong location):**
```bash
cd ~/dev/tools/yato && uv run yato loop start "prompt" --project "$(pwd)" ...
```

**CORRECT (loop created in user's project):**
```bash
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "prompt" --project "$PROJECT_DIR" ...
```

### Command Template

Run this pattern (do not modify the PROJECT_DIR capture):
```bash
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "PROMPT_HERE" \
  --session "$(date +%s)" \
  --project "$PROJECT_DIR" \
  --times N \  # OR --for "DURATION"
  --every "INTERVAL"  # Optional
```

### Examples

```bash
# Run 3 times with no delay
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "check the logs for errors" --session "$(date +%s)" --project "$PROJECT_DIR" --times 3

# Run every 5 minutes for 30 minutes
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "run the test suite" --session "$(date +%s)" --project "$PROJECT_DIR" --for "30m" --every "5m"

# Run 5 times with 1 minute interval
PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "check build status" --session "$(date +%s)" --project "$PROJECT_DIR" --times 5 --every "1m"
```

## Output Confirmation

After starting, confirm:
```
Loop started!
- Prompt: [first 50 chars of prompt]...
- Interval: [interval or "immediate"]
- Stop condition: [times or duration]

The loop will execute via the Stop hook each time you finish a task.
To cancel: /loop --cancel
```
</instructions>

<examples>
<example>
<input>/loop check the logs for errors --times 3</input>
<action>
1. Extract: prompt="check the logs for errors", times=3, interval=immediate
2. Run: PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "check the logs for errors" --session "$(date +%s)" --project "$PROJECT_DIR" --times 3
3. Confirm loop started
</action>
</example>

<example>
<input>/loop run tests --every 5m --for 1h</input>
<action>
1. Extract: prompt="run tests", duration="1h", interval="5m"
2. Run: PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop start "run tests" --session "$(date +%s)" --project "$PROJECT_DIR" --for "1h" --every "5m"
3. Confirm loop started
</action>
</example>

<example>
<input>/loop --cancel</input>
<action>
1. Detect cancel request
2. CRITICAL: List running loops with --project:
   PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop list --status running --project "$PROJECT_DIR"
3. If loops exist, use AskUserQuestion with options like:
   - "001-check-logs: check the logs for err..."
   - "002-run-tests: run the test suite..."
   - "Cancel all loops"
4. CRITICAL: Cancel with --project:
   PROJECT_DIR=$(pwd) && cd ~/dev/tools/yato && uv run yato loop cancel --loop-id "LOOP_ID" --project "$PROJECT_DIR"
5. Confirm: "Loop cancelled."
</action>
</example>

<example>
<input>/loop monitor the build</input>
<action>
1. Missing stop condition (no --times or --for)
2. Ask user: "How long should the loop run? Use --times N or --for DURATION (e.g., --times 5 or --for 30m)"
</action>
</example>
</examples>
