---
name: cancel-checkin
description: Cancel the automatic check-in loop. Use when you want to stop scheduled check-ins before all tasks are complete.
allowed-tools: Bash
user-invocable: true
disable-model-invocation: false
---

# Cancel Check-in

This skill cancels the automatic check-in loop.

<context>
The check-in system automatically continues until all tasks in tasks.json are complete (no pending or in_progress tasks remain). Use this skill to manually stop the check-ins before completion.

Check-ins are stored per-workflow in the project's `.workflow/<workflow>/checkins.json`.
</context>

<instructions>
Run the cancel-checkin.sh script from the project directory:

```bash
$HOME/dev/tools/yato/bin/cancel-checkin.sh
```

This cancels check-ins for the current project's active workflow (uses relative paths).

After running, confirm to the user that check-ins have been cancelled.
</instructions>

<output_format>
Check-in loop cancelled. No more automatic check-ins will be scheduled.
</output_format>
