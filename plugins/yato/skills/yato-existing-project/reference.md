# YAWF Existing Project - Reference

## Session Generation

### Session Name Algorithm

```bash
# Get project directory name
PROJECT_NAME=$(basename "$PROJECT_PATH")

# Convert to lowercase kebab-case
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')

# Session name = project slug + workflow name
SESSION_NAME="${PROJECT_SLUG}_${WORKFLOW_NAME}"
```

**Examples:**
- `My_Project` + `001-add-oauth` → `my-project_001-add-oauth`
- `UserAuthService` + `002-fix-bug` → `userauthservice_002-fix-bug`
- `task templates` + `001-new-workflow` → `task-templates_001-new-workflow`

## Troubleshooting

### Workflow Directory Creation Fails

**Issue:** `.workflow/` directory can't be created

**Solution:**
```bash
# Check permissions
ls -la .

# Create with sudo if needed
sudo mkdir -p .workflow

# Or use /tmp as fallback
mkdir -p /tmp/workflow-$(basename $PWD)
```

### Session Already Exists

**Issue:** tmux reports "duplicate session"

**Solution:**
```bash
# List existing sessions
tmux list-sessions

# Kill the existing session if stale
tmux kill-session -t SESSION_NAME
```

### Orchestrator Not Found

**Issue:** No such file or directory

**Solution:**
```bash
# Verify orchestrator path
ls -la ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py
```

## Integration Patterns

### With GitHub Issues

```bash
# Check for GitHub issues
gh issue list --limit 10
```

### With Documentation

```bash
# Check for docs
test -d docs && ls -la docs/
test -f README.md && echo "Has README"
test -f CONTRIBUTING.md && echo "Has contribution guide"
```

## Best Practices

1. **Verify session doesn't exist** - Check `tmux list-sessions` first
2. **Use the project root as cwd** - Ensure you're in the right directory before invoking
3. **Provide arguments when possible** - Giving a request upfront saves a round-trip with the PM
