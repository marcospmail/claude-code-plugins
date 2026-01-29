---
name: run-e2e-tests
description: Run end-to-end tests for the Yato tmux orchestrator project. Use this skill whenever you need to run tests, verify system functionality, execute the test suite, check that everything works, validate the codebase, or test tmux orchestrator features.
allowed-tools: Bash
---

# Run E2E Tests

<context>
Executes the comprehensive E2E test suite for Yato tmux orchestrator.
</context>

<instructions>
## Execute Test Suite

Run the E2E test script from the project root:

```bash
bash tests/e2e/run-all-tests.sh
```

### Verbose Output

For detailed test output, use the verbose flag:

```bash
bash tests/e2e/run-all-tests.sh --verbose
```

## What Gets Tested

The test suite covers:
- Agent creation and lifecycle
- Check-in scheduling and execution
- Workflow initialization and isolation
- PM notification system
- Task management and formatting
- Error handling
- Identity file configuration

## Expected Output

- Summary with total/passed/failed counts
- Individual test results
- List of failed tests (if any)
- Exit code 0 on success, 1 on failure
</instructions>
