---
name: yato-resume
description: Resume a workflow from where you left off. Restores the tmux session, PM, agents, and check-ins. Use when reopening a project to continue previous work.
allowed-tools: Bash,Read,Glob,Grep
user-invocable: true
disable-model-invocation: false
argument-hint: "[workflow-name or leave empty to list]"
---

# Yato Resume Workflow

<context>
This skill resumes a previously created workflow. When users close their browser or terminal and come back later, they can use this skill to restore everything - the tmux session, PM agent, all developer/QA agents, and check-ins - exactly where they left off.
</context>

<capabilities>
- Lists available workflows in a project if no argument provided
- Resumes a specific workflow by name (e.g., "001-add-user-auth")
- Restores tmux session with correct pane layout
- Recreates all agents from the workflow's agents/ folder
- Re-enables ralph loop if it was previously active
- Briefs the PM to continue from where the team left off
</capabilities>

<requirements>
- Yato installed at ${CLAUDE_PLUGIN_ROOT}
- A project with existing .workflow/ folder containing workflows
- Current directory should be the project root
</requirements>

<instructions>
## Step 1: Detect Project Path

Get the current working directory:

```bash
PROJECT_PATH=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')
```

Verify .workflow directory exists:
```bash
if [[ ! -d "$PROJECT_PATH/.workflow" ]]; then
    echo "No workflows found in this project."
    echo "Use /yato-existing-project or /yato-new-project to create one."
    exit 1
fi
```

## Step 2: Check for Arguments

Check if a workflow name was provided: `$ARGUMENTS`

**If $ARGUMENTS is empty**: List available workflows and ask user to pick one.

**If $ARGUMENTS is not empty**: Use it as the workflow name to resume.

## Step 3: List Workflows (if no argument)

If no argument provided, list available workflows:

```bash
${CLAUDE_PLUGIN_ROOT}/bin/resume-workflow.sh "$PROJECT_PATH"
```

This will show output like:
```
Available workflows in /path/to/project:

001-add-user-auth [in-progress] (current)
  Add user authentication
002-fix-payment-bug [completed]
  Fix payment processing bug

To resume a workflow, run:
  /yato-resume 001-add-user-auth
```

Then ask the user:
```
Which workflow would you like to resume?
Enter the workflow name (e.g., 001-add-user-auth):
```

WAIT for response.

## Step 4: Resume the Workflow

Run the resume-workflow script which:
- Creates/uses tmux session
- Sets up pane layout (Check-ins | PM)
- Recreates ALL agent windows from agents.yml
- Starts Claude in PM and each agent pane with correct model
- Re-enables ralph loop if it was active

```bash
${CLAUDE_PLUGIN_ROOT}/bin/resume-workflow.sh "$PROJECT_PATH" "$WORKFLOW_NAME"
```

Capture the session name from the output for the attach command.

## Step 5: Start Claude in PM Pane

After the script completes, start Claude in the PM pane:

```bash
# Get session name from project path
SESSION=$(basename "$PROJECT_PATH" | tr ' ' '-' | tr '[:upper:]' '[:lower:]')
PM_PANE="$SESSION:0.1"

# Start Claude Opus in PM pane
tmux send-keys -t "$PM_PANE" "claude --dangerously-skip-permissions --model opus" Enter
```

Wait 5 seconds for Claude to initialize, then brief the PM:

```bash
sleep 5
TMUX_SOCKET="${TMUX_SOCKET}" uv run --project ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/tmux_utils.py send --skip-suffix "$PM_PANE" "RESUMING WORKFLOW: $WORKFLOW_NAME

Read these files and continue from where you left off:
- .workflow/$WORKFLOW_NAME/agents/pm/instructions.md
- .workflow/$WORKFLOW_NAME/tasks.json
- .workflow/$WORKFLOW_NAME/prd.md
- .workflow/$WORKFLOW_NAME/agents.yml (shows agent windows)

Agents have been restored in their windows. Check tasks.json for pending tasks."
```

## Step 6: Inform User

Tell the user the workflow has been resumed and provide the attach command:

```
Workflow "$WORKFLOW_NAME" resumed.

All agents have been restored in their windows.
To connect: tmux attach -t $SESSION
```

That's all. Do not run any other tmux commands.
</instructions>

<workflow_summary>
1. Detect project path and compute project slug
2. Check for $ARGUMENTS (workflow name)
3. If no argument: list workflows, ask user to pick
4. Run resume-workflow.sh to restore session, PM pane, and all agent windows
5. Start Claude in PM pane
6. Brief PM with files to read and continue
7. Tell user the attach command
</workflow_summary>

<examples>
<example>
<scenario>User runs: /yato-resume 001-add-user-auth</scenario>
<action>
1. PROJECT_PATH = /Users/user/projects/my-app
2. WORKFLOW_NAME = "001-add-user-auth"
3. Run: resume-workflow.sh "$PROJECT_PATH" "001-add-user-auth"
4. Script restores session, PM pane, and all agent windows
5. Start Claude in PM pane: tmux send-keys -t "my-app:0.1" "claude --dangerously-skip-permissions --model opus" Enter
6. Brief PM with workflow files
7. Tell user: Workflow resumed. To connect: tmux attach -t my-app
</action>
</example>

<example>
<scenario>User runs: /yato-resume (no arguments)</scenario>
<action>
1. PROJECT_PATH = current directory
2. List available workflows using resume-workflow.sh
3. Ask: "Which workflow would you like to resume?"
4. User picks "002-fix-bug"
5. Run: resume-workflow.sh "$PROJECT_PATH" "002-fix-bug"
6. Start Claude in PM, brief PM
7. Tell user attach command
</action>
</example>

<example>
<scenario>User runs: /yato-resume in a project with no workflows</scenario>
<action>
1. Check .workflow directory doesn't exist
2. Tell user: No workflows found. Use /yato-existing-project or /yato-new-project.
</action>
</example>
</examples>

<output_format>
**If workflows exist and argument provided:**
```
Workflow "[WORKFLOW_NAME]" resumed.

All agents have been restored in their windows.
To connect: tmux attach -t [SESSION]
```

**If workflows exist but no argument:**
```
Available workflows:
[workflow list]

Which workflow would you like to resume?
```

**If no workflows:**
```
No workflows found. Use /yato-existing-project or /yato-new-project.
```
</output_format>
