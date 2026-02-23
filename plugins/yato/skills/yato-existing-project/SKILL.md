---
name: yato-existing-project
description: Work on an existing codebase with Yato (Yet Another Tmux Orchestrator). Creates a workflow folder, deploys a PM agent, and connects via tmux. PM handles all discovery, analysis, and planning. Use when user wants to add features, fix bugs, refactor, or work on any existing project.
allowed-tools: Bash,Read,Glob,Grep
user-invocable: true
disable-model-invocation: false
argument-hint: "[what to build: description, URL, or PRD]"
---

# YAWF Existing Project

<context>
This skill helps you work on an existing codebase using Yato (Yet Another Tmux Orchestrator). It is a thin launcher: set up infrastructure (workflow folder + tmux session), then hand off to the PM agent which handles all discovery, analysis, and planning.
</context>

<capabilities>
- Detects current directory as project path
- Detects if user is in tmux or not
- Creates workflow folder via init-workflow.sh
- Deploys PM agent via orchestrator
- Switches to PM session (in tmux) or gives attach command (not in tmux)
</capabilities>

<requirements>
- Yato installed at ${CLAUDE_PLUGIN_ROOT}
- Python 3 available
- Current directory should be the project root
</requirements>

<instructions>
## Step 1: Check if User is in Tmux

```bash
bash ${CLAUDE_PLUGIN_ROOT}/bin/check-tmux.sh
```

## Step 2: Get Project Info

```bash
PROJECT_PATH=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')
```

## Step 3: Create Workflow Folder

**CRITICAL**: Create the workflow folder FIRST to get the workflow name for the session.

If `$ARGUMENTS` is provided, use first 3-5 words as title. Otherwise use "new-workflow":

```bash
if [[ -n "$ARGUMENTS" ]]; then
    TITLE=$(echo "$ARGUMENTS" | cut -d' ' -f1-4)
else
    TITLE="new-workflow"
fi

# Create workflow folder (captures the folder name like "001-add-feature")
WORKFLOW_NAME=$(${CLAUDE_PLUGIN_ROOT}/bin/init-workflow.sh "$PROJECT_PATH" "$TITLE" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')

# If init-workflow.sh didn't output the name, get it from the newest folder
if [[ -z "$WORKFLOW_NAME" ]]; then
    WORKFLOW_NAME=$(ls -td "$PROJECT_PATH/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename)
fi
```

## Step 4: Save User's Request (if $ARGUMENTS provided)

**If $ARGUMENTS was provided**, add it to status.yml:

```bash
if [[ -n "$ARGUMENTS" ]]; then
    uv run --directory ${CLAUDE_PLUGIN_ROOT} python -c "
import sys
content = '''$ARGUMENTS'''
indented = '\n'.join('  ' + line if line else '' for line in content.split('\n'))
with open('$PROJECT_PATH/.workflow/$WORKFLOW_NAME/status.yml', 'r') as f:
    yml = f.read()
yml = yml.replace('initial_request: \"\"', 'initial_request: |\n' + indented)
with open('$PROJECT_PATH/.workflow/$WORKFLOW_NAME/status.yml', 'w') as f:
    f.write(yml)
"
fi
```

## Step 5: Compute Session Name and Deploy PM

Session name format: `{project}_{workflow}` (e.g., `my-project_001-add-feature`)

```bash
SESSION_NAME="${PROJECT_SLUG}_${WORKFLOW_NAME}"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "$WORKFLOW_NAME"
```

## Step 6: Connect or Give Attach Command

**If NOT in tmux:**

```bash
echo "tmux attach -t $SESSION_NAME" | pbcopy
```

**If $ARGUMENTS was provided**, output:
```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [SESSION_NAME]

The PM already has your request and will continue from there.
```

**If NO $ARGUMENTS**, output:
```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [SESSION_NAME]

The PM will ask you what you want to accomplish.
```

**If IN tmux:**

```bash
tmux switch-client -t "$SESSION_NAME"
```

The user is now in the PM session. The PM will read `status.yml` and either proceed with the request or ask the user what they want to accomplish.
</instructions>

<examples>
<example>
<scenario>User runs /yato-existing-project "Add OAuth" from REGULAR TERMINAL (not in tmux)</scenario>
<action>
1. Check tmux -> NOT_IN_TMUX
2. Get project info: my-app (slug), /Users/user/projects/my-app
3. Create workflow: init-workflow.sh "Add OAuth" -> WORKFLOW_NAME = "001-add-oauth"
4. Save $ARGUMENTS to status.yml initial_request field
5. Compute session: "my-app_001-add-oauth"
6. Deploy PM with: deploy-pm "my-app_001-add-oauth" -p ... -w "001-add-oauth"
7. Copy command: echo "tmux attach -t my-app_001-add-oauth" | pbcopy
8. Output: "Session ready! The PM already has your request..."
</action>
</example>

<example>
<scenario>User runs /yato-existing-project (no args) from INSIDE tmux</scenario>
<action>
1. Check tmux -> IN_TMUX
2. Get project info: my-project (slug)
3. Create workflow: init-workflow.sh "new-workflow" -> WORKFLOW_NAME = "001-new-workflow"
4. $ARGUMENTS is empty - do NOT add to status.yml
5. Compute session: "my-project_001-new-workflow"
6. Deploy PM with -w flag
7. tmux switch-client -t "my-project_001-new-workflow"
8. PM sees empty initial_request, asks what user wants to do
</action>
</example>
</examples>

<output_format>
**If NOT in tmux (with $ARGUMENTS):**
```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [SESSION_NAME]

The PM already has your request and will continue from there.
```

**If NOT in tmux (no arguments):**
```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [SESSION_NAME]

The PM will ask you what you want to accomplish.
```

**If IN tmux:**
```
Switching to PM session...
[User is now talking to PM]
```
</output_format>

## Additional Resources

- [reference.md](reference.md) - Session naming, troubleshooting, and integration patterns
- [examples.md](examples.md) - More usage examples and scenarios
