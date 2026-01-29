---
name: yawf-new-project
description: Start a new project from scratch using the tmux orchestrator. Creates a new tmux session with a Project Manager agent. Use when user wants to begin a new codebase or project.
allowed-tools: Bash,Read,Write
user-invocable: true
disable-model-invocation: false
argument-hint: "[project-name] [what to build: description, URL, or PRD]"
---

# YAWF New Project

<context>
This skill helps you start a completely new project from scratch using the tmux orchestrator system. It creates a new tmux session with a Project Manager agent who will coordinate the development work.
</context>

<capabilities>
- Creates project directory if needed
- Creates a new tmux session for the project
- Deploys a Project Manager agent to coordinate work
- AUTO-SWITCHES to the PM session if user is already in tmux
- Copies attach command if user is not in tmux
</capabilities>

<requirements>
- Tmux orchestrator installed at ~/dev/tools/tmux-orchestrator
- Python 3 available
- pbcopy command (macOS clipboard)
</requirements>

<instructions>
## Step 1: Gather Project Information

Check if the user provided arguments: `$1` (project name) and `$2` onwards (request).

**If $1 is not empty**: Use it as the project name.

**If $1 is empty**: Ask the user:
- "What is the project called? (use kebab-case, e.g., 'my-web-app')"

Then ask for project path:
- "Where should the project be located? (default: ~/projects/[project-name])"

If user doesn't specify path, use default: `~/projects/[project-name]`

## Step 2: Create Project Directory

```bash
PROJECT_PATH="${PROJECT_PATH:-$HOME/projects/$PROJECT_NAME}"
mkdir -p "$PROJECT_PATH"
```

## Step 3: Create Workflow Folder

**CRITICAL**: Create workflow folder FIRST to get the workflow name for session naming.

Determine workflow title from request or use "new-project":
```bash
if [[ -n "$REQUEST" ]]; then
    TITLE=$(echo "$REQUEST" | cut -d' ' -f1-4)
else
    TITLE="new-project"
fi

# Create workflow folder (captures the folder name like "001-build-recipe-app")
WORKFLOW_NAME=$(~/dev/tools/tmux-orchestrator/bin/init-workflow.sh "$PROJECT_PATH" "$TITLE" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')

# Fallback: get from newest folder
if [[ -z "$WORKFLOW_NAME" ]]; then
    WORKFLOW_NAME=$(ls -td "$PROJECT_PATH/.workflow"/[0-9][0-9][0-9]-*/ 2>/dev/null | head -1 | xargs basename)
fi
```

## Step 4: Create Initial PRD (if request was provided)

Check if the user provided a request: `$2` onwards (everything after project name).

**If $2 is not empty**: Create `.workflow/$WORKFLOW_NAME/prd.md` with the user's request:
```markdown
# Project Requirements: [PROJECT_NAME]

## User Request
> [Concatenate all arguments from $2 onwards - this is the full request]

## Project Context
- **Project**: [PROJECT_NAME]
- **Path**: [PROJECT_PATH]
- **Status**: New project

## Next Steps
The PM will ask clarifying questions to refine this into a detailed PRD.
```

Also add request to status.yml:
```bash
python3 -c "
import sys
content = '''$REQUEST'''
indented = '\n'.join('  ' + line if line else '' for line in content.split('\n'))
with open('$PROJECT_PATH/.workflow/$WORKFLOW_NAME/status.yml', 'r') as f:
    yml = f.read()
yml = yml.replace('initial_request: \"\"', 'initial_request: |\n' + indented)
with open('$PROJECT_PATH/.workflow/$WORKFLOW_NAME/status.yml', 'w') as f:
    f.write(yml)
"
```

**If $2 is empty**: Skip this step - PM will ask "What are we building?" interactively.

## Step 5: Compute Session Name and Deploy PM

Session name format: `{project}_{workflow}` (e.g., `recipe-manager_001-build-recipe-app`)

```bash
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')
SESSION_NAME="${PROJECT_SLUG}_${WORKFLOW_NAME}"
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "$WORKFLOW_NAME"
```

## Step 6: Connect to PM Session

Check if user is already in tmux and handle accordingly:

```bash
if [ -n "$TMUX" ]; then
    # User is already in tmux - switch to new session seamlessly
    tmux switch-client -t "$SESSION_NAME"
    echo "Switched to session: $SESSION_NAME"
else
    # User is not in tmux - copy attach command
    echo "tmux attach -t $SESSION_NAME" | pbcopy
    echo "NOT_IN_TMUX"
fi
```

## Step 7: Inform User

**If user was in tmux**: They are now in the PM session. Done!

**If user was NOT in tmux**: Tell them:
```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [SESSION_NAME]

The PM will ask what you want to build and guide you from there.
```

## What Happens After Connection

The user is now talking to the PM directly. The PM will:

**If request was provided ($2 not empty)**:
1. Read the initial PRD with the user's request
2. Summarize understanding
3. Ask clarifying questions to refine requirements
4. Create a detailed PRD
5. Propose a team structure
6. Wait for approval, then deploy agents and begin work

**If NO request was provided ($2 empty)**:
1. Ask "What are we building? (You can provide: a brief description, a URL, a PRD link, or paste a full PRD)"
2. Gather requirements through conversational discovery
3. Create a detailed PRD
4. Propose a team structure
5. Wait for approval, then deploy agents and begin work
</instructions>

<examples>
<example>
<scenario>User runs: /yawf-new-project recipe-manager Build a recipe sharing web app with user auth</scenario>
<action>
1. $1 = "recipe-manager" (project name)
2. $2 onwards = "Build a recipe sharing web app with user auth" (request)
3. Ask: "Where should it be located? (default: ~/projects/recipe-manager)"
4. User: "default is fine"
5. Create directory: mkdir -p ~/projects/recipe-manager
6. Create workflow: init-workflow.sh → WORKFLOW_NAME = "001-build-recipe-sharing"
7. Create .workflow/001-build-recipe-sharing/prd.md with user's request
8. Compute session: SESSION_NAME = "recipe-manager_001-build-recipe-sharing"
9. Deploy PM: deploy-pm "recipe-manager_001-build-recipe-sharing" -p ... -w "001-build-recipe-sharing"
10. Check if in tmux and connect
11. PM reads prd.md, summarizes understanding, asks clarifying questions
</action>
</example>

<example>
<scenario>User runs: /yawf-new-project (no arguments)</scenario>
<action>
1. $1 is empty - ask: "What would you like to name this project? (e.g., my-web-app)"
2. User: "task-tracker"
3. Ask: "Where should it be located? (default: ~/projects/task-tracker)"
4. User: "default is fine"
5. Create directory: mkdir -p ~/projects/task-tracker
6. Create workflow: init-workflow.sh "new-project" → WORKFLOW_NAME = "001-new-project"
7. No PRD created (will ask interactively)
8. Compute session: SESSION_NAME = "task-tracker_001-new-project"
9. Deploy PM with -w flag
10. Check if in tmux and connect
11. PM asks: "What are we building?"
</action>
</example>
</examples>

<output_format>
If in tmux (seamless):
```
Creating project: [PROJECT_NAME]
Path: [PROJECT_PATH]
Workflow: [WORKFLOW_NAME]
Deploying PM...
Switching to PM session...
[User is now talking to PM]
```

If not in tmux:
```
Creating project: [PROJECT_NAME]
Path: [PROJECT_PATH]
Workflow: [WORKFLOW_NAME]
Deploying PM...

Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t [PROJECT]_[WORKFLOW_NAME]

The PM will ask what you want to build and guide you from there.
```
</output_format>

## Additional Resources

- [reference.md](reference.md) - Complete command reference and orchestrator details
- [examples.md](examples.md) - More usage examples and scenarios
