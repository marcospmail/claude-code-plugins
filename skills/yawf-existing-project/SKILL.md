---
name: yawf-existing-project
description: Work on an existing codebase with the tmux orchestrator. If NOT in tmux, deploys PM and gives attach command (PM handles discovery). If IN tmux, performs analysis, creates context files, and seamlessly switches to PM. Use when user wants to add features, fix bugs, refactor, or work on any existing project.
allowed-tools: Bash,Read,Write,Glob,Grep,Edit
user-invocable: true
disable-model-invocation: false
argument-hint: "[what to build: description, URL, or PRD]"
---

# YAWF Existing Project

<context>
This skill helps you work on an existing codebase using the tmux orchestrator system. The workflow differs based on whether you're already in tmux or not:
- **In tmux**: Full analysis, create context files, seamlessly switch to PM session
- **Not in tmux**: Just deploy PM and give attach command - PM handles discovery
</context>

<capabilities>
- Detects current directory as project path
- Detects if user is in tmux or not
- If IN tmux: Full workflow with analysis and context files
- If NOT in tmux: Quick deploy, PM handles everything after attach
</capabilities>

<requirements>
- Tmux orchestrator installed at ~/dev/tools/tmux-orchestrator
- Python 3 available
- Current directory should be the project root
</requirements>

<instructions>
## Step 0: CRITICAL - Check if User is in Tmux FIRST

**THIS MUST BE THE VERY FIRST THING YOU DO:**

```bash
if [ -n "$TMUX" ]; then
    echo "IN_TMUX"
else
    echo "NOT_IN_TMUX"
fi
```

**Based on the result, follow DIFFERENT workflows:**

---

# WORKFLOW A: User is NOT in tmux (NOT_IN_TMUX)

When user is NOT in tmux, create workflow folder, deploy PM with unique session, and give attach command.

## A1: Get Project Info

```bash
PROJECT_PATH=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')
```

## A2: Create Workflow Folder

**CRITICAL**: Create the workflow folder FIRST to get the workflow name for the session.

If `$ARGUMENTS` is provided, use first 3-5 words as title. Otherwise use "new-workflow":

```bash
if [[ -n "$ARGUMENTS" ]]; then
    TITLE=$(echo "$ARGUMENTS" | cut -d' ' -f1-4)
else
    TITLE="new-workflow"
fi

# Create workflow folder (captures the folder name like "001-add-feature")
WORKFLOW_NAME=$(~/dev/tools/tmux-orchestrator/bin/init-workflow.sh "$PROJECT_PATH" "$TITLE" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')

# If init-workflow.sh didn't output the name, get it from the newest folder
if [[ -z "$WORKFLOW_NAME" ]]; then
    WORKFLOW_NAME=$(ls -td "$PROJECT_PATH/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename)
fi
```

## A3: Save User's Request (if $ARGUMENTS provided)

**If $ARGUMENTS was provided**, add it to status.yml:

```bash
if [[ -n "$ARGUMENTS" ]]; then
    python3 -c "
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

## A4: Compute Session Name and Deploy PM

Session name format: `{project}_{workflow}` (e.g., `my-project_001-add-feature`)

```bash
SESSION_NAME="${PROJECT_SLUG}_${WORKFLOW_NAME}"
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "$WORKFLOW_NAME"
```

## A5: Give User the Attach Command

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

**STOP HERE for NOT_IN_TMUX workflow. Do NOT create PRD/analysis files.**

---

# WORKFLOW B: User IS in tmux (IN_TMUX)

When user IS in tmux, do the full workflow: analysis, create files, seamlessly switch to PM.

## B1: Detect Project Path and Quick Overview

```bash
PROJECT_PATH=$(pwd)
PROJECT_NAME=$(basename "$PROJECT_PATH")
```

Quick scan to identify project type:
```bash
ls -la | head -20
test -f package.json && echo "Node.js project detected"
test -f requirements.txt && echo "Python project detected"
test -f go.mod && echo "Go project detected"
test -f Cargo.toml && echo "Rust project detected"
```

Tell the user: "I see this is a [PROJECT_TYPE] project at [PATH]."

## B2: Get What They Want to Accomplish

Check if arguments were provided: `$ARGUMENTS`

**If $ARGUMENTS is not empty**: Use it directly as the user's request. Skip to Step B3.

**If $ARGUMENTS is empty**: Ask the user:
```
What would you like to accomplish in this project?

You can provide:
- A brief description (e.g., "Add user authentication", "Fix the login bug")
- A URL to a file or specific line in your repo
- A link to a PRD document
- A full PRD pasted directly
```

WAIT for their response before proceeding.

## B3: Targeted Codebase Analysis (Use Haiku Sub-Agent)

**IMPORTANT**: Use the Task tool with `model: "haiku"` and `subagent_type: "Explore"` for this step.

```
Task tool parameters:
- subagent_type: "Explore"
- model: "haiku"
- prompt: "Analyze this codebase for: [USER'S REQUEST].
  Find:
  1. Related files (search for keywords related to the request)
  2. Current implementation patterns
  3. Integration points where new code will connect
  4. Existing patterns to follow

  Return a structured analysis with:
  - Relevant Project Structure (only dirs/files related to request)
  - Current Implementation (how related features work)
  - Integration Points (files to modify, new files needed, dependencies)
  - Patterns to Follow
  - Considerations (conflicts, backward compatibility, tests to update)"
```

## B4: Create Workflow Folder First

**CRITICAL**: Create workflow folder FIRST to get the workflow name for session naming.

```bash
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')

# Use first 3-5 words of user request as title
TITLE=$(echo "[USER'S REQUEST]" | cut -d' ' -f1-4)

# Create workflow folder
WORKFLOW_NAME=$(~/dev/tools/tmux-orchestrator/bin/init-workflow.sh "$PROJECT_PATH" "$TITLE" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')

# Fallback: get from newest folder
if [[ -z "$WORKFLOW_NAME" ]]; then
    WORKFLOW_NAME=$(ls -td "$PROJECT_PATH/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename)
fi
```

## B5: Create Context Files in Workflow Folder

Create files INSIDE `.workflow/$WORKFLOW_NAME/`:

### Create `.workflow/$WORKFLOW_NAME/prd.md`

```markdown
# Project Requirements: [USER'S REQUEST]

## User Request
> [EXACT quote of what user said they want to accomplish]

## Project Context
- **Project**: [PROJECT_NAME]
- **Type**: [Node.js/Python/etc]
- **Path**: [PROJECT_PATH]

## Scope
[Brief description of what needs to be done]

## Technical Details
See [codebase-analysis.md](./codebase-analysis.md) for:
- Relevant files and integration points
- Current implementation patterns
- Detailed technical considerations
```

### Create `.workflow/$WORKFLOW_NAME/codebase-analysis.md`

```markdown
# Codebase Analysis for: [USER'S REQUEST]

## Relevant Project Structure
[Only the directories/files relevant to this request]

## Current Implementation
[How related features work today]

## Integration Points
- **Files to Modify**: [List specific files]
- **New Files Needed**: [List new files to create]
- **Dependencies**: [Existing modules this will depend on]

## Patterns to Follow
[Existing patterns in the codebase that should be followed]

## Considerations
- [Potential conflicts]
- [Backward compatibility]
- [Related tests to update]
```

### Create `.workflow/$WORKFLOW_NAME/tasks.json`

```json
{
  "tasks": [],
  "metadata": {
    "created": "ISO-8601 timestamp",
    "updated": "ISO-8601 timestamp",
    "note": "Tasks will be added by PM after team proposal is approved"
  }
}
```

## B6: Generate Session Name and Deploy PM

Session name format: `{project}_{workflow}` (e.g., `my-project_001-add-oauth`)

```bash
SESSION_NAME="${PROJECT_SLUG}_${WORKFLOW_NAME}"
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "$WORKFLOW_NAME"
```

## B7: Switch to PM Session (Seamless)

```bash
tmux switch-client -t "$SESSION_NAME"
```

The user is now in the PM session with full context. The PM will:
1. Read `.workflow/$WORKFLOW_NAME/prd.md` and see the user's request
2. NOT ask again what the user wants (context already provided)
3. Summarize what it understood and ask for any clarifications
4. Propose a team
5. Proceed with normal workflow
</instructions>

<workflow_summary>
**WORKFLOW A (NOT in tmux):**
1. Check tmux → NOT_IN_TMUX
2. Get project info (path, name, slug)
3. Create workflow folder with init-workflow.sh → get WORKFLOW_NAME
4. Save user's request to status.yml (if provided)
5. Compute session name: `{project}_{workflow}`
6. Deploy PM with -w workflow flag
7. Give user attach command
8. STOP - PM handles discovery after attach

**WORKFLOW B (IN tmux):**
1. Check tmux → IN_TMUX
2. Quick scan → Identify project type
3. ASK → "What do you want to accomplish?" (or use $ARGUMENTS)
4. Create workflow folder with init-workflow.sh → get WORKFLOW_NAME
5. Targeted analysis → Only relevant files (Haiku sub-agent)
6. Create .workflow/$WORKFLOW_NAME/prd.md, codebase-analysis.md, tasks.json
7. Compute session name: `{project}_{workflow}`
8. Deploy PM with -w workflow flag and switch client (seamless)
9. PM reads context, skips discovery, proposes team
</workflow_summary>

<examples>
<example>
<scenario>User runs /yawf-existing-project "Add hourly cron" from REGULAR TERMINAL (not in tmux)</scenario>
<action>
1. Check tmux → NOT_IN_TMUX
2. Get project info: marcosp-com (slug), /Users/user/projects/marcosp.com
3. Create workflow: init-workflow.sh → WORKFLOW_NAME = "001-add-hourly-cron"
4. Save $ARGUMENTS to status.yml initial_request field
5. Compute session: "marcosp-com_001-add-hourly-cron"
6. Deploy PM with: deploy-pm "marcosp-com_001-add-hourly-cron" -p ... -w "001-add-hourly-cron"
7. Copy command: echo "tmux attach -t marcosp-com_001-add-hourly-cron" | pbcopy
8. Output: "Session ready! The PM already has your request..."
9. STOP HERE - User attaches and PM continues
</action>
</example>

<example>
<scenario>User runs /yawf-existing-project (no args) from REGULAR TERMINAL (not in tmux)</scenario>
<action>
1. Check tmux → NOT_IN_TMUX
2. Get project info: my-project (slug)
3. Create workflow: init-workflow.sh "new-workflow" → WORKFLOW_NAME = "001-new-workflow"
4. $ARGUMENTS is empty - do NOT add to status.yml
5. Compute session: "my-project_001-new-workflow"
6. Deploy PM with -w flag
7. Output: "Session ready! The PM will ask you what you want to accomplish."
8. User attaches, PM asks what they want to do
</action>
</example>

<example>
<scenario>User runs /yawf-existing-project "Add OAuth" from INSIDE tmux</scenario>
<action>
1. Check tmux → IN_TMUX
2. Quick scan: "I see this is a Next.js project at /Users/user/projects/my-app"
3. $ARGUMENTS = "Add OAuth" (use directly)
4. Create workflow: init-workflow.sh "Add OAuth" → WORKFLOW_NAME = "001-add-oauth"
5. Targeted analysis using Haiku sub-agent
6. Create .workflow/001-add-oauth/prd.md, codebase-analysis.md, tasks.json
7. Compute session: "my-app_001-add-oauth"
8. Deploy PM: deploy-pm "my-app_001-add-oauth" -p ... -w "001-add-oauth"
9. tmux switch-client -t "my-app_001-add-oauth" (seamless)
10. PM reads prd.md, proposes team
</action>
</example>

<example>
<scenario>User runs /yawf-existing-project (no args) from INSIDE tmux</scenario>
<action>
1. Check tmux → IN_TMUX
2. Quick scan: "I see this is a Python/FastAPI project"
3. $ARGUMENTS is empty - ask: "What would you like to accomplish?"
4. WAIT for response
5. User says: "Add user authentication"
6. Create workflow: init-workflow.sh "Add user authentication" → WORKFLOW_NAME = "001-add-user-authentication"
7. Targeted analysis using Haiku sub-agent
8. Create .workflow/001-add-user-authentication/prd.md, codebase-analysis.md, tasks.json
9. Compute session: "my-project_001-add-user-authentication"
10. Deploy PM with -w flag and switch client
11. PM reads context, proposes team
</action>
</example>
</examples>

<output_format>
**If NOT in tmux:**
```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [SESSION_NAME]

The PM will ask you what you want to accomplish.
```

**If IN tmux (with $ARGUMENTS):**
```
Project: [PROJECT_NAME] ([PROJECT_TYPE])
Path: [PROJECT_PATH]

Analyzing relevant codebase areas for: [USER REQUEST]
...analysis...

Created:
- .workflow/prd.md
- .workflow/codebase-analysis.md
- .workflow/tasks.json

Switching to PM session...
[User is now talking to PM - PM already has context]
```

**If IN tmux (no arguments):**
```
Project: [PROJECT_NAME] ([PROJECT_TYPE])
Path: [PROJECT_PATH]

What would you like to accomplish in this project?
> [WAIT FOR USER RESPONSE]

---
[Continue with analysis and context file creation]
```
</output_format>

## Additional Resources

- [reference.md](reference.md) - Complete command reference and orchestrator details
- [examples.md](examples.md) - More usage examples and scenarios
