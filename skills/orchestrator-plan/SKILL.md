---
name: orchestrator-plan
description: Plan a project by gathering requirements, analyzing codebase, generating PRD and team config
user-invocable: false
disable-model-invocation: true
---

# Plan Project with Dynamic Team Generation

You are the orchestrator planning a new project. Follow this workflow to gather requirements, understand the codebase (if existing), generate a PRD, and create a dynamic team configuration.

## Arguments
- path: Project directory path (existing or new) (required)

## Phase 1: Understand the Project Type

First, check if this is a new or existing project:

```bash
ls -la $ARGUMENTS 2>/dev/null | head -20
```

Based on the result:
- **Empty/non-existent directory**: This is a NEW project
- **Has files**: This is an EXISTING project - analyze the codebase

## Phase 2: Requirements Gathering

Ask the user these questions (adapt based on project type):

### For NEW Projects:
1. "What do you want to build? Describe the project in 2-3 sentences."
2. "Who are the target users?"
3. "What are the MUST-HAVE features? (list them)"
4. "What are the NICE-TO-HAVE features?"
5. "Any tech stack preferences? (e.g., React, Python, vanilla JS)"
6. "Any constraints? (time, specific libraries to use/avoid)"

### For EXISTING Projects:
1. "What do you want to add or change?"
2. "Which parts of the codebase will this affect?"
3. "Are there any specific requirements or constraints?"

**IMPORTANT**: Do NOT proceed until you have clear answers. Ask follow-up questions if anything is ambiguous.

## Phase 3: Codebase Analysis (Existing Projects Only)

If this is an existing project, analyze it:

```bash
# Check project type
ls $ARGUMENTS/package.json $ARGUMENTS/requirements.txt $ARGUMENTS/go.mod $ARGUMENTS/Cargo.toml 2>/dev/null

# Check directory structure
ls -la $ARGUMENTS/

# Check for framework indicators
cat $ARGUMENTS/package.json 2>/dev/null | head -30
```

Identify:
- Tech stack (languages, frameworks)
- Project structure (src/, app/, components/, etc.)
- Where new code should be added
- Existing patterns to follow

## Phase 4: Generate PRD

Based on gathered requirements, create a PRD file.

## Phase 5: Generate Team Configuration

Based on the PRD complexity, generate a team-config.json:

**Simple project** (1-3 features, single tech): 1 PM + 1 Developer
**Medium project** (4-6 features, frontend+backend): 1 PM + 2 Developers
**Complex project** (7+ features, multiple systems): 1 PM + 3+ Developers + QA

## Phase 6: Deploy the Team

Once user approves:

```bash
ORCHESTRATOR_PATH="$HOME/dev/tools/tmux-orchestrator"

# Get session name from path
SESSION_NAME=$(basename $ARGUMENTS)

# Deploy the team with the config
python3 $ORCHESTRATOR_PATH/lib/orchestrator.py deploy $SESSION_NAME -p $ARGUMENTS -c $ARGUMENTS/team-config.json

# Start Claude and brief all agents
python3 $ORCHESTRATOR_PATH/lib/orchestrator.py start
```
