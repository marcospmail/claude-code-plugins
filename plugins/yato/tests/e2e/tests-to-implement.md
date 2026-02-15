# E2E Tests Implementation Status

This file tracks all end-to-end tests for the yato workflow.

## Current Coverage: 13 Tests | 116+ Assertions

### Agent Creation & Registry
- [x] **test-agent-creation.sh** - Basic agent creation (developer + qa) - 13 assertions
- [x] **test-smart-naming-duplicates.sh** - Smart naming with duplicate roles (qa-1, qa-2) - 11 assertions
- [x] **test-single-agent.sh** - Single agent creation (just qa) - 3 assertions
- [x] **test-agent-models.sh** - Verify correct models assigned (opus for reviewer, sonnet for dev) - 4 assertions
- [x] **test-agent-identity-files.sh** - Identity.yml and instructions.md content - 13 assertions

### Workflow Initialization
- [x] **test-workflow-init.sh** - Workflow folder structure, status.yml, agents.yml - 14 assertions
- [x] **test-workflow-numbering.sh** - Multiple workflows get sequential numbers (001, 002, 003) - 5 assertions

### Workflow Resume
- [x] **test-workflow-resume.sh** - Resume paused workflow (session, panes, agents, checkins, layout) - 28 assertions

### Communication
- [x] **test-notify-pm.sh** - Agent can notify PM using notify-pm.sh - 7 assertions
- [x] **test-send-message.sh** - Messages delivered to correct tmux targets - 5 assertions

### PM Behavior
- [x] **test-pm-checkin-askuser.sh** - PM briefing includes AskUserQuestion for check-in frequency
- [x] **test-pm-discovery-questions.sh** - PM briefing includes discovery question instructions (8 assertions)

### Error Handling
- [x] **test-error-handling.sh** - Proper error messages for various conditions - 5 assertions

## Summary

| Category | Tests | Status |
|----------|-------|--------|
| Agent Creation | 5 | ✅ All Pass |
| Workflow Init | 2 | ✅ All Pass |
| Workflow Resume | 1 | ✅ All Pass |
| Communication | 2 | ✅ All Pass |
| PM Behavior | 2 | ✅ All Pass |
| Error Handling | 1 | ✅ Pass |
| **TOTAL** | **13** | **✅ 100%** |

## Run All Tests

```bash
# Run all tests (minimal output)
./tests/e2e/run-all-tests.sh

# Run all tests (verbose)
./tests/e2e/run-all-tests.sh --verbose

# Run single test
./tests/e2e/test-agent-creation.sh
```

## Future Tests to Consider

- [ ] **test-checkin-schedule.sh** - Check-in scheduling and cancellation
- [ ] **test-pm-briefing-content.sh** - Full PM briefing content validation
- [ ] **test-agent-task-assignment.sh** - task_manager.py assign functionality
- [ ] **test-ralph-loop.sh** - Ralph oversight loop setup
