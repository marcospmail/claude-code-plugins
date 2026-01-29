# YAWF New Project - Examples

## Example 1: Simple Web Application

<example>
<scenario>User wants to create a new web application for a to-do list</scenario>
<action>

**User:** "I want to start a new to-do list web app"

**Assistant:**
1. "What would you like to name the tmux session for this project?"
   **User:** "todo-app"

2. "Where should the project be located?"
   **User:** "~/projects/todo-app"

3. Deploy the PM:
```bash
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm todo-app -p ~/projects/todo-app
```

4. Copy attach command:
```bash
echo "tmux attach-session -t todo-app" | pbcopy
```

5. Inform user:
```
Session created: todo-app
Project path: ~/projects/todo-app
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t todo-app

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Example 2: Microservice Project

<example>
<scenario>User wants to create a new authentication microservice</scenario>
<action>

**User:** "Create a new auth service for our platform"

**Assistant:**
1. "What should we name this session?"
   **User:** "auth-service"

2. "Where should this microservice be located?"
   **User:** "~/work/microservices/auth-service"

3. Deploy:
```bash
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm auth-service -p ~/work/microservices/auth-service
```

4. Copy:
```bash
echo "tmux attach-session -t auth-service" | pbcopy
```

5. Output:
```
Session created: auth-service
Project path: ~/work/microservices/auth-service
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t auth-service

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Example 3: Mobile App Backend

<example>
<scenario>User is starting a backend API for a mobile application</scenario>
<action>

**User:** "I need a backend for my fitness tracking app"

**Assistant:**
1. "What name would you like for the session?"
   **User:** "fitness-api"

2. "Where should we set up the project?"
   **User:** "~/projects/fitness-tracker/backend"

3. Deploy:
```bash
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm fitness-api -p ~/projects/fitness-tracker/backend
```

4. Copy:
```bash
echo "tmux attach-session -t fitness-api" | pbcopy
```

5. Response:
```
Session created: fitness-api
Project path: ~/projects/fitness-tracker/backend
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t fitness-api

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Example 4: Client Project with Specific Naming

<example>
<scenario>User is creating a project for a client with specific requirements</scenario>
<action>

**User:** "Set up a new project for Acme Corp's dashboard"

**Assistant:**
1. "What should the session be named?"
   **User:** "acme-dashboard"

2. "Where should this be located?"
   **User:** "~/clients/acme-corp/dashboard"

3. Deploy:
```bash
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm acme-dashboard -p ~/clients/acme-corp/dashboard
```

4. Copy:
```bash
echo "tmux attach-session -t acme-dashboard" | pbcopy
```

5. Output:
```
Session created: acme-dashboard
Project path: ~/clients/acme-corp/dashboard
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t acme-dashboard

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Example 5: Quick Setup with Defaults

<example>
<scenario>User wants to start quickly with minimal questions</scenario>
<action>

**User:** "Quick start a new project called 'blog-engine' in ~/projects"

**Assistant:**
(Infer defaults and confirm)

"I'll create a session named 'blog-engine' at ~/projects/blog-engine. Is that correct?"
**User:** "Yes"

Deploy:
```bash
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm blog-engine -p ~/projects/blog-engine
```

Copy:
```bash
echo "tmux attach-session -t blog-engine" | pbcopy
```

Output:
```
Session created: blog-engine
Project path: ~/projects/blog-engine
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t blog-engine

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Example 6: Handling Path Creation

<example>
<scenario>User specifies a path that doesn't exist yet</scenario>
<action>

**User:** "Create a new e-commerce platform"

**Assistant:**
1. "Session name?"
   **User:** "ecommerce-platform"

2. "Project path?"
   **User:** "~/new-ventures/ecommerce"

3. Create directory first:
```bash
mkdir -p ~/new-ventures/ecommerce
```

4. Deploy:
```bash
python3 ~/dev/tools/tmux-orchestrator/lib/orchestrator.py deploy-pm ecommerce-platform -p ~/new-ventures/ecommerce
```

5. Copy:
```bash
echo "tmux attach-session -t ecommerce-platform" | pbcopy
```

6. Response:
```
Created directory: ~/new-ventures/ecommerce
Session created: ecommerce-platform
Project path: ~/new-ventures/ecommerce
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t ecommerce-platform

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Common Patterns Summary

| User Intent | Session Name | Project Path |
|-------------|--------------|--------------|
| Personal project | `project-name` | `~/projects/project-name` |
| Work project | `project-name` | `~/work/project-name` |
| Client work | `client-project` | `~/clients/client-name/project` |
| Microservice | `service-name` | `~/work/services/service-name` |
| Experiment | `experiment-name` | `~/experiments/experiment-name` |
