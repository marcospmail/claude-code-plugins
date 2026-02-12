---
name: test-workflow
description: Guide for testing Yato workflow features through tmux sessions with Claude CLI. Use this skill whenever you need to test PM deployment, team proposals, task generation, agent creation, or workflow behavior.
allowed-tools: Bash, Read
user-invocable: false
---

# Test Workflow

<context>
Testing Yato workflow features requires using tmux sessions with Claude CLI to simulate real plugin behavior. Direct script execution bypasses the actual flow and doesn't test how the PM agent interacts with users.
</context>

<instructions>
## Testing Philosophy

**CRITICAL:** Tests MUST use tmux + Claude CLI, NOT direct script execution.

### Why Tmux Sessions Matter

| Approach | Tests | Misses |
|----------|-------|--------|
| **Direct scripts** | Script logic only | PM interaction, user flow, tmux messaging |
| **Tmux + Claude** | Full workflow | Nothing - tests real plugin behavior |

## Testing Workflow Features

### 1. Deploy PM Agent

```bash
# Create test project
TEST_DIR="/tmp/test-yato-$$"
mkdir -p "$TEST_DIR"
echo "test project" > "$TEST_DIR/README.md"

# Deploy PM
uv run python lib/orchestrator.py deploy-pm test-session -p "$TEST_DIR"

# Attach to see PM in action
tmux attach -t test-session
```

**What this tests:**
- PM deployment with check-in display pane
- Planning briefing delivery
- Initial discovery questions

### 2. Test Team Structure Proposal

```bash
# After PM deployed, interact via tmux send-keys
tmux send-keys -t test-session:0.1 "Add user authentication" Enter

# Wait and capture PM response
sleep 3
tmux capture-pane -t test-session:0.1 -p | tail -30

# Verify PM asks discovery questions (not creates team immediately)
```

**What this tests:**
- PM conversational behavior
- Discovery question flow
- Team proposal format

### 3. Test Team Structure Saving

```bash
# Send user approval
tmux send-keys -t test-session:0.1 "yes, that team looks good" Enter

# Capture PM actions
sleep 5
tmux capture-pane -t test-session:0.1 -p | tail -40

# Verify team.yml created
ls -la "$TEST_DIR/.workflow/001-*/team.yml"
cat "$TEST_DIR/.workflow/001-*/team.yml"
```

**What this tests:**
- Team approval flow
- team.yml file creation
- Correct agent structure format

### 4. Test Task Generation

```bash
# PM should now create tasks - verify tasks.json
WORKFLOW_DIR=$(ls -d "$TEST_DIR/.workflow/001-"* | head -1)
cat "$WORKFLOW_DIR/tasks.json"

# Verify tasks assigned to agents from team.yml
```

**What this tests:**
- PRD to tasks conversion
- Agent assignments match team.yml
- Task format (id, subject, description, activeForm, agent, status, blockedBy, blocks)

### 5. Test Agent Creation

```bash
# PM should use create-team.sh after user types "start"
# Verify agents were created in new windows
tmux list-windows -t test-session

# Check agents.yml registry
cat "$WORKFLOW_DIR/agents.yml"
```

**What this tests:**
- create-team.sh execution
- Window creation for agents
- agents.yml population with window numbers

### 6. Cleanup

```bash
# Kill test session
tmux kill-session -t test-session

# Remove test directory
rm -rf "$TEST_DIR"
```

## Common Testing Mistakes

### ❌ WRONG: Direct Script Execution

```bash
# This bypasses PM interaction flow
source bin/workflow-utils.sh
save_team_structure "$TEST_DIR" "developer:developer:sonnet"
```

**Why it's wrong:** Doesn't test how PM proposes team or how user approves it.

### ✅ CORRECT: Tmux Interaction

```bash
# Deploy PM
uv run python lib/orchestrator.py deploy-pm test-session -p "$TEST_DIR"

# Simulate user input
tmux send-keys -t test-session:0.1 "add auth feature" Enter

# Observe PM behavior
tmux capture-pane -t test-session:0.1 -p | tail -30
```

**Why it's correct:** Tests actual user → PM → workflow flow.

## Verification Checklist

After testing, verify these workflow files:

```bash
WORKFLOW_DIR=$(ls -d "$TEST_DIR/.workflow/001-"* | head -1)

# [ ] status.yml exists and contains initial_request
cat "$WORKFLOW_DIR/status.yml"

# [ ] team.yml created after user approves team
cat "$WORKFLOW_DIR/team.yml"

# [ ] tasks.json created with agents from team.yml
cat "$WORKFLOW_DIR/tasks.json"

# [ ] agents.yml populated after create-team.sh
cat "$WORKFLOW_DIR/agents.yml"

# [ ] Agent identity files created
ls -la "$WORKFLOW_DIR/agents/"
```

## Observing Tmux Sessions

### Capture Recent Output

```bash
# Last 30 lines from PM pane
tmux capture-pane -t test-session:0.1 -p | tail -30

# Check-in display (pane 0)
tmux capture-pane -t test-session:0.0 -p
```

### List Windows (Agents)

```bash
# See all agent windows
tmux list-windows -t test-session

# Expected: 0:Orchestrator, 1:developer, 2:qa, etc.
```

### Send Messages to Agents

```bash
# Use send-message.sh to communicate
bin/send-message.sh test-session:1 "Check your agent-tasks.md"

# Verify message received
tmux capture-pane -t test-session:1 -p | tail -20
```

## Test Patterns from E2E Tests

Reference these patterns from tests/e2e/:

### Pattern 1: Structure Verification (test-workflow-init.sh)

```bash
# Direct file checks for structure
[[ -f "$WORKFLOW_DIR/status.yml" ]] && echo "✅ status.yml"
[[ -f "$WORKFLOW_DIR/team.yml" ]] && echo "✅ team.yml"
grep -q "^pm:" "$WORKFLOW_DIR/agents.yml" && echo "✅ PM entry"
```

### Pattern 2: PM Behavior Verification (test-pm-discovery-questions.sh)

```bash
# Check PM briefing contains proper instructions
grep -q "What are we building" lib/orchestrator.py && echo "✅ New project question"
grep -q "What would you like to accomplish" lib/orchestrator.py && echo "✅ Existing project question"
```

### Pattern 3: Integration Testing

```bash
# Full workflow: deploy → interact → verify
uv run python lib/orchestrator.py deploy-pm test -p /tmp/test
tmux send-keys -t test:0.1 "Add feature X" Enter
sleep 5
WORKFLOW=$(tmux showenv -t test WORKFLOW_NAME | cut -d= -f2)
[[ -f "/tmp/test/.workflow/$WORKFLOW/prd.md" ]] && echo "✅ PRD created"
```

## Key Files to Monitor

| File | What It Shows |
|------|---------------|
| `.workflow/001-*/status.yml` | Workflow state, session, check-in interval |
| `.workflow/001-*/team.yml` | Proposed team structure (before agents created) |
| `.workflow/001-*/tasks.json` | Generated tasks with agent assignments |
| `.workflow/001-*/agents.yml` | Runtime agent registry (after agents created) |
| `.workflow/001-*/prd.md` | Requirements document |

## Debugging Tips

### PM Not Creating Team

```bash
# Check PM received briefing
tmux capture-pane -t test-session:0.1 -p -S -100 | grep "WORKFLOW:"

# Verify WORKFLOW_NAME env var set
tmux showenv -t test-session WORKFLOW_NAME
```

### team.yml Not Created

```bash
# PM should call save_team_structure after user approval
# Check PM output for this bash execution
tmux capture-pane -t test-session:0.1 -p -S -200 | grep "save_team_structure"
```

### tasks.json Missing Agents

```bash
# Verify team.yml exists first
cat "$WORKFLOW_DIR/team.yml"

# tasks.json agents MUST match team.yml agent names
# PM should only assign tasks to agents defined in team.yml
```

</instructions>

<guidelines>
## When to Use This Skill

- Testing new workflow features
- Verifying PM behavior changes
- Debugging agent creation issues
- Validating workflow file generation
- Creating integration tests

## Success Criteria

A proper test:
- Uses tmux sessions, not direct script calls
- Simulates user interaction via send-keys
- Observes output via capture-pane
- Verifies workflow files after interaction
- Cleans up test sessions and directories
</guidelines>
