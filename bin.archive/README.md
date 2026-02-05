# Archived Bash Scripts

These bash scripts have been migrated to Python modules.

## Migration Date
2026-02-02

## Replacement Mapping

| Old Script | New Module | CLI Command |
|------------|------------|-------------|
| send-message.sh | lib/tmux_utils.py | `yato send` |
| notify-pm.sh | lib/tmux_utils.py | `yato notify` |
| restart-checkin-display.sh | lib/tmux_utils.py | `yato restart-checkin-display` |
| schedule-checkin.sh | lib/checkin_scheduler.py | `yato checkin schedule` |
| cancel-checkin.sh | lib/checkin_scheduler.py | `yato checkin cancel` |
| checkin-display.sh | lib/checkin_scheduler.py | `yato checkin list` |
| assign-task.sh | lib/task_manager.py | `yato tasks assign` |
| tasks-display.sh | lib/task_manager.py | `yato tasks display` |
| tasks-table.sh | lib/task_manager.py | `yato tasks table` |
| workflow-utils.sh | lib/workflow_ops.py | `yato workflow` |
| init-workflow.sh | lib/workflow_ops.py | `yato workflow create` |
| create-agent.sh | lib/agent_manager.py | `yato agent create` |
| init-agent-files.sh | lib/agent_manager.py | `yato agent init-files` |
| create-team.sh | lib/agent_manager.py | (via AgentManager.create_team) |
| setup-pm-loop.sh | lib/orchestrator.py | (via orchestrator) |
| resume-workflow.sh | lib/orchestrator.py | (via orchestrator) |

## Using the New CLI

```bash
# Run any command
cd ~/dev/tools/yato
uv run yato <command> [options]

# Examples
uv run yato send session:1 "Hello agent"
uv run yato notify "[DONE] Task completed"
uv run yato checkin schedule 15 --note "Check progress"
uv run yato checkin cancel
uv run yato tasks table
uv run yato workflow list
uv run yato agent create myproject developer -p ~/myproject
```

## Why Archive Instead of Delete?

These scripts are preserved for:
1. Git history reference
2. Understanding the original bash implementations
3. Fallback if Python migration has issues
