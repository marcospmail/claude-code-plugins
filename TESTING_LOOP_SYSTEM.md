# Loop System Testing Guide

## Overview

The loop system uses Claude Code's Stop hook to execute repeating prompts. This guide covers testing the loop functionality end-to-end.

## Quick Verification

### 1. Verify Loop Creation

```bash
cd /tmp/test-loop-$$
PROJECT_DIR=$(pwd)
cd ~/dev/tools/yato

uv run yato loop start "echo hello" \
  --session "test-$$" \
  --project "$PROJECT_DIR" \
  --times 2
```

Expected output:
```
Loop started: 001-echo-hello
Folder: /tmp/test-loop-xxx/.workflow/loops/001-echo-hello
Interval: immediate (no delay)
Will stop after: 2 executions
```

### 2. Verify Loop Metadata

Check the meta.json file was created:

```bash
cd /tmp/test-loop-$$
cat .workflow/loops/001-echo-hello/meta.json
```

Expected structure:
```json
{
  "should_continue": true,
  "prompt": "echo hello",
  "interval_seconds": 0,
  "stop_after_times": 2,
  "execution_count": 0,
  "session_id": "test-xxx",
  "project_path": "/tmp/test-loop-xxx",
  ...
}
```

### 3. Verify Hook Execution

Test the Stop hook manually:

```bash
export YATO_LOOP_DEBUG=true

echo '{"model": "haiku", "session_id": "test"}' | \
  python3 ~/dev/tools/yato/hooks/scripts/loop-stop-hook.py
```

Expected output:
```json
{
  "decision": "block",
  "reason": "[Loop 1/2] echo hello"
}
```

Check debug log:
```bash
cat ~/.yato/loop-stop-hook.log | tail -10
```

Expected log entries:
```
[START] loop-stop-hook invoked
[INPUT] Received: {"model": "haiku", ...}
[LOOPS] Found 1 active loops
[META] Loaded: exec_count=0
[CONDITIONS] should_stop=False, reason=
[OUTPUT] Continuing loop: [Loop 1/2]
```

## Testing with Manchete

### Prerequisites

- Manchete project in `~/dev/manchete-view-transitions` (or configured path)
- Brave MCP configured in Claude Code
- SQLite database for proposals: `manchete_proposals.db`

### Test Procedure

1. **Start loop in manchete directory:**

```bash
cd ~/dev/manchete-view-transitions  # or actual path
/loop "Search for latest Brazilian news and generate daily word proposals using brave search" --times 2 --every 5m
```

2. **Monitor Claude execution:**

- Watch the Claude terminal for the loop prompt being executed
- Verify "[Loop 1/2]" prefix appears in the prompt
- Confirm brave search MCP is being used (check tool calls in Claude)

3. **Verify database updates:**

```bash
# Check proposals database
ls -la manchete_proposals.db

# Query proposals
sqlite3 manchete_proposals.db "SELECT COUNT(*) FROM proposals"

# View latest proposals
sqlite3 manchete_proposals.db "SELECT * FROM proposals ORDER BY created_at DESC LIMIT 3"
```

4. **Debug if needed:**

Enable hook debug logging:
```bash
YATO_LOOP_DEBUG=true /loop "..." --times 2
```

Then check logs:
```bash
tail -50 ~/.yato/loop-stop-hook.log
```

## Troubleshooting

### Loop not executing

**Symptoms:** "[Loop 1/2]" prefix doesn't appear, loop status file isn't updated

**Check:**
1. Loop registry: `cat ~/.yato/active-loops.json`
2. Loop folder exists: `ls -la .workflow/loops/`
3. Hook debug log: `YATO_LOOP_DEBUG=true` then retry
4. Claude Code version: Verify Stop hook is supported

### Hook not producing output

**Symptoms:** Claude keeps stopping instead of continuing

**Check:**
1. Hook configuration in `hooks/hooks.json`:
   - Verify `"matcher": "*"` is set
   - Verify `"passInput": true` is set
2. Hook file permissions: `ls -l ~/dev/tools/yato/hooks/scripts/loop-stop-hook.py`
3. Python execution: `python3 --version` and test import

### Proposals not generating

**Symptoms:** Loop runs but manchete_proposals.db not updated

**Check:**
1. Brave MCP is registered in Claude Code hooks
2. Prompt includes "using brave search" or similar instruction
3. Claude has permission to write to database directory
4. Database schema exists (check with sqlite3)

## Environment Variables

### YATO_LOOP_DEBUG

Enable detailed logging of hook execution:

```bash
export YATO_LOOP_DEBUG=true
# Logs to ~/.yato/loop-stop-hook.log
```

## Files Involved

- **Loop creation:** `lib/cli.py` → `cmd_loop_start()`
- **Loop execution:** `lib/loop_manager.py` → `LoopManager` class
- **Hook execution:** `hooks/scripts/loop-stop-hook.py`
- **Hook config:** `hooks/hooks.json`
- **Loop state:** `.workflow/loops/<NNN-name>/meta.json`
- **Registry:** `~/.yato/active-loops.json`

## Expected Behavior

### Loop with --times 2

1. First execution:
   - Prompt: "[Loop 1/2] <your prompt>"
   - Execution count updated to 1
   - Sleep for interval (if any)

2. Second execution:
   - Prompt: "[Loop 2/2] <your prompt>"
   - Execution count updated to 2
   - Stop conditions met, loop stops

### Loop with --for 30m and --every 5m

1. Executes every 5 minutes
2. Status shows elapsed time: "[Loop 3, 10m/30m]"
3. Continues until 30 minutes elapsed
4. Automatically stops when duration exceeded

## Fixing Common Issues

### Fix 1: Stop hook not triggering

**Problem:** Hook configuration missing matcher

**Solution:**
```json
{
  "Stop": [
    {
      "matcher": "*",
      "hooks": [
        {
          "type": "command",
          "command": "python3 ${CLAUDE_PLUGIN_ROOT}/hooks/scripts/loop-stop-hook.py",
          "passInput": true
        }
      ]
    }
  ]
}
```

### Fix 2: Hook receives no input

**Problem:** `passInput` not set in hook config

**Solution:** Add `"passInput": true` to hook configuration

### Fix 3: Loop state not persisted

**Problem:** Loop stops even though conditions not met

**Solution:**
1. Verify `should_continue: true` in meta.json
2. Check execution_count is incrementing
3. Verify stop_after_times/stop_after_seconds set correctly

## Verification Script

Run the automated verification:

```bash
bash /tmp/verify-loop-system.sh
```

Or manually test with:

```bash
# Create test loop
cd /tmp/test-$$
uv run yato loop start "test" --session "$$" --project "$(pwd)" --times 1

# Test hook
echo '{}' | python3 ~/dev/tools/yato/hooks/scripts/loop-stop-hook.py | jq .
```

