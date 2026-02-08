---
name: notify-pm
description: Notify the Project Manager with a status update. Use this to report task completion, blockers, questions, or progress. Only for agents (developer, qa), NOT for PM.
allowed-tools: Bash
user-invocable: false
disable-model-invocation: false
---

# Notify PM

Send a notification message to the Project Manager (PM).

## Arguments
- message: Status message with type prefix (required)

## Message Types
- `[DONE] ...` - Task completed
- `[BLOCKED] ...` - Cannot proceed, need help
- `[HELP] ...` - Question for the PM
- `[STATUS] ...` - Progress update
- `[PROGRESS] ...` - Work in progress update

## Steps

1. **Send the notification:**
```bash
$HOME/dev/tools/yato/bin/notify-pm.sh "<message>"
```

2. **Confirm** the message was sent by checking the output for "Message sent".

## Examples
```
/notify-pm [DONE] Completed task T1 - implemented login endpoint
/notify-pm [BLOCKED] Need database credentials to proceed
/notify-pm [HELP] Should I use REST or GraphQL for the new API?
/notify-pm [STATUS] 3 of 5 subtasks complete
```
