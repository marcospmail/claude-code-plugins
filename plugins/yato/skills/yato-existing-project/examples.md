# YAWF Existing Project - Examples

## Example 1: With Args, NOT in Tmux

<example>
<scenario>User runs /yato-existing-project "Add a shopping cart" from a regular terminal (not in tmux), in a Next.js project</scenario>
<action>

**User:** (in directory ~/projects/ecommerce-app) `/yato-existing-project "Add a shopping cart"`

**Assistant:**

1. Check tmux:
```bash
if [ -n "$TMUX" ]; then echo "IN_TMUX"; else echo "NOT_IN_TMUX"; fi
# NOT_IN_TMUX
```

2. Get project info:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/projects/ecommerce-app
PROJECT_NAME=$(basename "$PROJECT_PATH")
# ecommerce-app
PROJECT_SLUG=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '._ ' '-')
# ecommerce-app
```

3. Create workflow folder:
```bash
TITLE=$(echo "Add a shopping cart" | cut -d' ' -f1-4)
# "Add a shopping cart"
WORKFLOW_NAME=$(${CLAUDE_PLUGIN_ROOT}/bin/init-workflow.sh "$PROJECT_PATH" "$TITLE" 2>/dev/null | grep "^Workflow:" | awk '{print $2}')
# 001-add-a-shopping-cart
```

4. Save request to status.yml (since $ARGUMENTS is provided)

5. Deploy PM:
```bash
SESSION_NAME="ecommerce-app_001-add-a-shopping-cart"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "001-add-a-shopping-cart"
```

6. Copy attach command and output:
```bash
echo "tmux attach -t ecommerce-app_001-add-a-shopping-cart" | pbcopy
```

```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t ecommerce-app_001-add-a-shopping-cart

The PM already has your request and will continue from there.
```
</action>
</example>

## Example 2: With Args, IN Tmux

<example>
<scenario>User runs /yato-existing-project "Fix the JWT token expiration bug" from inside tmux, in a FastAPI project</scenario>
<action>

**User:** (in directory ~/work/api-backend, inside tmux) `/yato-existing-project "Fix the JWT token expiration bug"`

**Assistant:**

1. Check tmux:
```bash
if [ -n "$TMUX" ]; then echo "IN_TMUX"; else echo "NOT_IN_TMUX"; fi
# IN_TMUX
```

2. Get project info:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/work/api-backend
PROJECT_SLUG="api-backend"
```

3. Create workflow folder:
```bash
TITLE=$(echo "Fix the JWT token" | cut -d' ' -f1-4)
WORKFLOW_NAME="001-fix-the-jwt-token"
```

4. Save request to status.yml

5. Deploy PM:
```bash
SESSION_NAME="api-backend_001-fix-the-jwt-token"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "001-fix-the-jwt-token"
```

6. Switch client (seamless):
```bash
tmux switch-client -t "api-backend_001-fix-the-jwt-token"
```

PM reads status.yml, sees the request, summarizes understanding, and asks for confirmation.
</action>
</example>

## Example 3: No Args, NOT in Tmux

<example>
<scenario>User runs /yato-existing-project with no arguments from a regular terminal</scenario>
<action>

**User:** (in directory ~/projects/my-app) `/yato-existing-project`

**Assistant:**

1. Check tmux:
```bash
if [ -n "$TMUX" ]; then echo "IN_TMUX"; else echo "NOT_IN_TMUX"; fi
# NOT_IN_TMUX
```

2. Get project info:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/projects/my-app
PROJECT_SLUG="my-app"
```

3. Create workflow folder with default title:
```bash
TITLE="new-workflow"
WORKFLOW_NAME="001-new-workflow"
```

4. $ARGUMENTS is empty - skip status.yml update

5. Deploy PM:
```bash
SESSION_NAME="my-app_001-new-workflow"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "001-new-workflow"
```

6. Copy attach command and output:
```bash
echo "tmux attach -t my-app_001-new-workflow" | pbcopy
```

```
Session ready!

Paste and press Enter to connect: (already copied to clipboard)
tmux attach -t my-app_001-new-workflow

The PM will ask you what you want to accomplish.
```
</action>
</example>

## Example 4: No Args, IN Tmux

<example>
<scenario>User runs /yato-existing-project with no arguments from inside tmux</scenario>
<action>

**User:** (in directory ~/work/company-monorepo, inside tmux) `/yato-existing-project`

**Assistant:**

1. Check tmux:
```bash
if [ -n "$TMUX" ]; then echo "IN_TMUX"; else echo "NOT_IN_TMUX"; fi
# IN_TMUX
```

2. Get project info:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/work/company-monorepo
PROJECT_SLUG="company-monorepo"
```

3. Create workflow folder with default title:
```bash
TITLE="new-workflow"
WORKFLOW_NAME="001-new-workflow"
```

4. $ARGUMENTS is empty - skip status.yml update

5. Deploy PM:
```bash
SESSION_NAME="company-monorepo_001-new-workflow"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH" -w "001-new-workflow"
```

6. Switch client (seamless):
```bash
tmux switch-client -t "company-monorepo_001-new-workflow"
```

PM sees empty initial_request in status.yml, asks the user what they want to accomplish.
</action>
</example>
