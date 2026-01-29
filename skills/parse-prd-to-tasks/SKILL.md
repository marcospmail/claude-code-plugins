---
name: parse-prd-to-tasks
description: Parse PRD into tasks.json with agent assignments. Used by PM after PRD is complete.
user-invocable: false
disable-model-invocation: true
allowed-tools: Bash,Read,Write,Glob,Grep
argument-hint: [workflow-path]
---

<context>
## Purpose
This skill is used by the Project Manager in Yato (Yet Another Tmux Orchestrator) to break down a PRD (Product Requirements Document) into actionable tasks with agent assignments.

## Workflow Context
- **Input:** PRD file from the workflow folder (prd.md)
- **Output:** tasks.json file with tasks assigned to appropriate agents (developer, qa, code-reviewer)
- **Location:** Workflow folder structure (.workflow/[workflow-name]/)
</context>

<instructions>
## Step 1: Locate the PRD

Determine the workflow path:
- If $ARGUMENTS is provided, use it as the workflow path
- Otherwise, get workflow name from tmux environment variable

Get workflow name from tmux env:
```bash
WORKFLOW_NAME=$(tmux showenv WORKFLOW_NAME 2>/dev/null | cut -d= -f2)
```

If workflow found, set paths:
- WORKFLOW_PATH=".workflow/$WORKFLOW_NAME"
- PRD_PATH="$WORKFLOW_PATH/prd.md"

If no active workflow found, output error and stop.

Read the PRD file using the Read tool.

## Step 2: Identify Available Agents

Reference the standard Yato team structure:

| Agent | Role | Can Modify Code | Typical Tasks |
|-------|------|-----------------|---------------|
| developer | Implementation | YES | Write code, implement features, fix bugs |
| qa | Testing | NO | Write tests, verify functionality, report issues |
| code-reviewer | Review | NO | Review code, check security, approve changes |

Optional specialized agents (if mentioned in PRD):
- backend-developer, frontend-developer, designer, devops

## Step 3: Analyze PRD and Create Tasks

Analyze the PRD thoroughly and decompose it into specific, actionable tasks.

**Task Assignment Rules:**
1. **Implementation tasks** → Assign to `developer`
2. **Testing tasks** → Assign to `qa`
3. **Review tasks** → Assign to `code-reviewer`

## Step 4: Determine Dependencies

Establish task dependencies using task IDs (T1, T2, T3...):
- QA tasks depend on their corresponding implementation tasks
- Review tasks depend on implementation tasks being complete
- Some implementation tasks may have sequential dependencies
- Use empty array `[]` for tasks with no dependencies

## Step 5: Generate tasks.json

Use the Write tool to create the tasks.json file in the workflow folder with this JSON format:

```json
{
  "tasks": [
    {
      "id": "T1",
      "subject": "Brief task title (imperative form)",
      "description": "Detailed description with acceptance criteria",
      "activeForm": "Present continuous form for status display (e.g., 'Implementing user auth')",
      "agent": "developer",
      "status": "pending",
      "blockedBy": [],
      "blocks": ["T2", "T3"]
    },
    {
      "id": "T2",
      "subject": "Write unit tests for user auth",
      "description": "Test login, logout, token refresh endpoints",
      "activeForm": "Writing unit tests for user auth",
      "agent": "qa",
      "status": "pending",
      "blockedBy": ["T1"],
      "blocks": []
    }
  ],
  "metadata": {
    "created": "ISO-8601 timestamp",
    "updated": "ISO-8601 timestamp",
    "prd": "prd.md"
  }
}
```

**Task Fields:**
- `id`: Unique identifier (T1, T2, T3...)
- `subject`: Brief imperative title (e.g., "Implement login endpoint")
- `description`: Detailed requirements and acceptance criteria
- `activeForm`: Present continuous form for display (e.g., "Implementing login endpoint")
- `agent`: Single agent assignment (developer, qa, code-reviewer)
- `status`: Always starts as "pending" (other values: in_progress, blocked, completed)
- `blockedBy`: Array of task IDs that must complete before this task can start
- `blocks`: Array of task IDs that are waiting on this task

## Step 6: Output Summary

After generating tasks.json, provide a clear summary:
- Total number of tasks created
- Task breakdown per agent (developer: X, qa: Y, code-reviewer: Z)
- Absolute file path to tasks.json
- Confirmation that file was written successfully
</instructions>

<guidelines>
## Writing Quality Tasks

**DO:**
- Be specific with file paths: "Implement hourly cron in scheduler/index.ts" not "Add cron"
- Include clear acceptance criteria in the description field
- Keep tasks focused and achievable (1-2 hours max per task)
- Reference specific functions, files, or sections from the PRD
- Use consistent naming conventions for task IDs (T1, T2, T3...)
- Write activeForm in present continuous tense

**DON'T:**
- Create vague tasks like "Implement feature" or "Fix bugs"
- Assign multiple unrelated changes to a single task
- Skip testing or review tasks (every implementation needs verification)
- Create circular dependencies in blockedBy/blocks
- Make tasks too large or complex
</guidelines>

<constraints>
- Always read the full PRD before creating tasks
- Every implementation task should have a corresponding QA task
- Code changes should have a review task
- Use specific file paths when mentioned in PRD
- blockedBy/blocks must reference valid task IDs
- Status should always start as "pending"
- Output must be valid JSON
</constraints>
