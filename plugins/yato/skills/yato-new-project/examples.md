# YAWF New Project - Examples

## Example 1: Full Args with Project Name

<example>
<scenario>User provides project name and description</scenario>
<action>

**User:** `/yato-new-project tictactoe a simple tic-tac-toe game`

**Assistant:**

1. Parse args: PROJECT_NAME = "tictactoe", REQUEST = "a simple tic-tac-toe game"

2. Create project directory:
```bash
PROJECT_PATH="$HOME/dev/tictactoe"
mkdir -p "$PROJECT_PATH"
PROJECT_SLUG="tictactoe"
```

3. Create workflow folder:
```bash
TITLE="a simple tic-tac-toe"
WORKFLOW_NAME="001-a-simple-tic-tac-toe"
```

4. Save request to status.yml

5. Deploy PM:
```bash
SESSION_NAME="tictactoe_001-a-simple-tic-tac-toe"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "$WORKFLOW_NAME"
```

6. Output:
```
Project created at: ~/dev/tictactoe

Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t tictactoe_001-a-simple-tic-tac-toe

The PM has your request and will continue from there.
```
</action>
</example>

## Example 2: Description Only (Name Derived)

<example>
<scenario>User provides only a description, project name is derived</scenario>
<action>

**User:** `/yato-new-project a recipe sharing app`

**Assistant:**

1. Parse args: no explicit name, derive PROJECT_NAME = "recipe-sharing-app", REQUEST = "a recipe sharing app"

2. Create project directory:
```bash
PROJECT_PATH="$HOME/dev/recipe-sharing-app"
mkdir -p "$PROJECT_PATH"
PROJECT_SLUG="recipe-sharing-app"
```

3. Create workflow, save request

4. Deploy PM:
```bash
SESSION_NAME="recipe-sharing-app_001-a-recipe-sharing-app"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "001-a-recipe-sharing-app"
```

5. Output:
```
Project created at: ~/dev/recipe-sharing-app

Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t recipe-sharing-app_001-a-recipe-sharing-app

The PM has your request and will continue from there.
```
</action>
</example>

## Example 3: No Args (Ask for Name Only)

<example>
<scenario>User provides no arguments at all</scenario>
<action>

**User:** `/yato-new-project`

**Assistant:**

1. No arguments - ask for project name only:
   "What should the project be called?"
   **User:** "weather-dashboard"

2. PROJECT_NAME = "weather-dashboard", REQUEST is empty

3. Create project directory:
```bash
PROJECT_PATH="$HOME/dev/weather-dashboard"
mkdir -p "$PROJECT_PATH"
```

4. Create workflow with default title "new-project"

5. Skip status.yml update (no request)

6. Deploy PM:
```bash
SESSION_NAME="weather-dashboard_001-new-project"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "001-new-project"
```

7. Output:
```
Project created at: ~/dev/weather-dashboard

Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t weather-dashboard_001-new-project

The PM will ask you what you want to build.
```
</action>
</example>

## Example 4: In Tmux with Full Args

<example>
<scenario>User runs the skill from inside tmux with full arguments</scenario>
<action>

**User:** (inside tmux) `/yato-new-project blog-engine a markdown-powered blog`

**Assistant:**

1. Check tmux → IN_TMUX
2. PROJECT_NAME = "blog-engine", REQUEST = "a markdown-powered blog"
3. Create ~/dev/blog-engine/
4. Create workflow, save request
5. Deploy PM
6. Switch client (seamless):
```bash
tmux switch-client -t "blog-engine_001-a-markdown-powered-blog"
```

PM reads status.yml, sees the request, and proceeds.
</action>
</example>
