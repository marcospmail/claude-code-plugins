# Loop

**Repeat any Claude Code prompt at intervals with configurable stop conditions.** A Claude Code plugin for executing recurring tasks - check logs, run tests, monitor builds, or any prompt on a schedule.

## Installation

In Claude Code, run:

```
/plugin marketplace add marcospmail/claude-code-plugins
/plugin install loop@claude-code-plugins
```

### Requirements

- **Python >= 3.10** - With croniter (`uv` handles dependencies automatically)
- **Claude Code**

## Usage

```
/loop [prompt] [--times N | --for DURATION | --forever] [--every INTERVAL | --cron CRON_EXPR]
```

### Stop Conditions (pick one)

| Flag | Behavior |
|------|----------|
| `--times N` | Stop after N executions |
| `--for DURATION` | Stop after time elapsed (e.g., `30m`, `2h`, `1h30m`) |
| `--forever` | Run until manually cancelled with `/loop --cancel` |

If omitted, you'll be prompted to choose.

### Scheduling (optional)

| Flag | Behavior |
|------|----------|
| `--every INTERVAL` | Wait between executions (e.g., `30s`, `5m`, `2h`) |
| `--cron EXPRESSION` | Standard 5-field cron schedule (e.g., `0 12 * * *`) |

`--every` and `--cron` are mutually exclusive. Without either, executions run back-to-back.

### Cancel

```
/loop --cancel
```

Lists active loops and lets you choose which to cancel.

## Examples

```bash
# Check logs 3 times, no delay between runs
/loop check the logs for errors --times 3

# Run tests every 5 minutes for 1 hour
/loop run the test suite --for 1h --every 5m

# Monitor build status 5 times, 1 minute apart
/loop check build status --times 5 --every 1m

# Watch for deployments forever, checking every 10 minutes
/loop check for new deployments --forever --every 10m

# Daily health check at noon
/loop check system health --cron "0 12 * * *"

# Weekday checks at 9am and 5pm, 10 times total
/loop check status --cron "0 9,17 * * 1-5" --times 10
```

## How It Works

Loop uses Claude Code's **Stop hook** mechanism - no background processes or queues needed.

1. `/loop` creates a metadata file in `.workflow/loops/<name>/meta.json`
2. The first iteration executes immediately (except with `--cron`, which waits for the next match)
3. When Claude finishes responding, the Stop hook checks for active loops
4. If the loop should continue, the hook sleeps for the interval and injects the next prompt
5. This repeats until stop conditions are met or the loop is cancelled

### Time Formats

Supports flexible duration strings for `--every` and `--for`:

| Format | Example |
|--------|---------|
| Seconds | `30s` |
| Minutes | `5m` |
| Hours | `2h` |
| Compound | `1h30m`, `2h30m15s` |

### Cron Expressions

Standard 5-field format: `minute hour day-of-month month day-of-week`

| Expression | Schedule |
|-----------|----------|
| `0 12 * * *` | Daily at noon |
| `*/5 * * * *` | Every 5 minutes |
| `0 9,17 * * 1-5` | 9am & 5pm on weekdays |
| `0 0 1 * *` | First day of each month |
| `30 2 * * 0` | Every Sunday at 2:30am |

### Session and Project Isolation

- Loops are stored per-project in `.workflow/loops/`
- Each loop is tied to the Claude Code session that created it
- Multiple projects can have independent loops running simultaneously

## License

MIT
