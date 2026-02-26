---
name: yato
description: Yato orchestrator entry point. Presents workflow options (new project, existing project, resume) and delegates to the appropriate skill. Use when user invokes /yato without specifying a sub-command.
allowed-tools: AskUserQuestion,Skill
user-invocable: true
disable-model-invocation: false
argument-hint: ""
---

# Yato

Unified entry point for Yato (Yet Another Tmux Orchestrator).

## Instructions

If $ARGUMENTS is not empty, try to match it to one of the options below and skip the question:
- If it contains "new" → invoke `yato:yato-new-project` with the remaining arguments
- If it contains "existing" or "exist" → invoke `yato:yato-existing-project` with the remaining arguments
- If it contains "resume" → invoke `yato:yato-resume` with the remaining arguments
- If it contains "cleanup" or "clean" or "teardown" → invoke `yato:yato-cleanup` with the remaining arguments
- Otherwise, show the choice menu below

If $ARGUMENTS is empty, use the AskUserQuestion tool to ask the user:

**Question:** "What would you like to do?"
**Header:** "Yato"
**Options:**
1. **Label:** "New project" — **Description:** "Start a new project from scratch"
2. **Label:** "Existing project" — **Description:** "Work on an existing codebase"
3. **Label:** "Resume" — **Description:** "Resume a previous workflow"
4. **Label:** "Cleanup" — **Description:** "Tear down a running workflow session"

Then, based on the user's selection:
- **New project** → invoke skill `yato:yato-new-project`
- **Existing project** → invoke skill `yato:yato-existing-project`
- **Resume** → invoke skill `yato:yato-resume`
- **Cleanup** → invoke skill `yato:yato-cleanup`

If the user selects "Other" and provides custom text, try to interpret their intent and match it to one of the above options. If unclear, ask for clarification.
