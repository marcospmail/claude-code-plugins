# YAWF Existing Project - Examples

## Example 1: Next.js Application - Adding Feature

<example>
<scenario>User is in a Next.js e-commerce project and wants to add a shopping cart feature</scenario>
<action>

**User:** (in directory ~/projects/ecommerce-app) "I want to add a shopping cart"

**Assistant:**

1. Detect project path:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/projects/ecommerce-app
```

2. Analyze codebase:
```bash
# Check package.json
cat package.json
# Found: Next.js 14.0.0, React 18, TypeScript, Tailwind CSS

# Check structure
ls -la
# app/, components/, lib/, public/, prisma/

# Check for existing docs
cat README.md | head -20
```

3. Create analysis file:
```markdown
# Codebase Analysis

## Project Overview
**Name:** ecommerce-app
**Type:** Full-stack e-commerce web application
**Purpose:** Online store with product catalog and checkout

## Tech Stack
- **Language:** TypeScript
- **Framework:** Next.js 14 (App Router)
- **Styling:** Tailwind CSS
- **Database:** PostgreSQL with Prisma ORM
- **State:** React Context API

## Key Modules
- `app/` - Next.js app router pages
- `components/` - Reusable React components
- `lib/` - Utility functions and API helpers
- `prisma/` - Database schema and migrations

## Patterns
- Server Components for data fetching
- Client Components for interactivity
- API routes in app/api/
```

4. Ask for objective:
"What would you like to work on in this project?"
**User:** "Add a shopping cart feature with add/remove items and checkout"

5. Generate session name:
```bash
SESSION_NAME="ecommerce-app"
```

6. Deploy PM:
```bash
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm ecommerce-app -p /Users/username/projects/ecommerce-app
```

7. Copy attach:
```bash
echo "tmux attach-session -t ecommerce-app" | pbcopy
```

8. Output:
```
Codebase Analysis Complete!
Analysis saved to: .workflow/codebase-analysis.md

Project: ecommerce-app
Path: /Users/username/projects/ecommerce-app
Tech Stack: Next.js 14 + TypeScript + Prisma

Objective: Add shopping cart feature with add/remove items and checkout

Session created: ecommerce-app
Attach command copied to clipboard!

To connect to your session:
  tmux attach-session -t ecommerce-app

Or simply paste from clipboard (Cmd+V)
```
</action>
</example>

## Example 2: Python FastAPI - Bug Fix

<example>
<scenario>User has a FastAPI backend with a bug in authentication</scenario>
<action>

**User:** (in ~/work/api-backend) "Fix the authentication bug"

**Assistant:**

1. Detect path:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/work/api-backend
```

2. Analyze:
```bash
# Check requirements.txt
cat requirements.txt
# FastAPI, SQLAlchemy, PyJWT, uvicorn

# Check structure
find . -maxdepth 2 -type d
# ./app, ./app/routers, ./app/models, ./app/schemas, ./tests

# Check main entry
cat app/main.py | head -30
```

3. Create analysis:
```markdown
# Codebase Analysis

## Project Overview
**Name:** api-backend
**Type:** REST API backend service
**Purpose:** Authentication and user management API

## Tech Stack
- **Language:** Python 3.11
- **Framework:** FastAPI
- **Database:** PostgreSQL with SQLAlchemy
- **Auth:** JWT tokens

## Architecture
Clean Architecture pattern with routers, models, schemas separation

## Key Modules
- `app/routers/` - API endpoints
- `app/models/` - SQLAlchemy models
- `app/schemas/` - Pydantic schemas
- `app/auth/` - Authentication logic
```

4. Ask objective:
"What bug are you trying to fix?"
**User:** "JWT tokens are expiring too quickly, should be 24 hours not 1 hour"

5. Generate session:
```bash
SESSION_NAME="api-backend"
```

6. Deploy:
```bash
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm api-backend -p /Users/username/work/api-backend
```

7. Output:
```
Codebase Analysis Complete!
Analysis saved to: .workflow/codebase-analysis.md

Project: api-backend
Path: /Users/username/work/api-backend
Tech Stack: Python FastAPI + SQLAlchemy + JWT

Objective: Fix JWT token expiration (should be 24 hours, currently 1 hour)

Session created: api-backend
Attach command copied to clipboard!
```
</action>
</example>

## Example 3: React Library - Refactoring

<example>
<scenario>User wants to refactor a React component library to TypeScript</scenario>
<action>

**User:** (in ~/projects/ui-components) "Migrate this to TypeScript"

**Assistant:**

1. Detect path:
```bash
PROJECT_PATH=$(pwd)
# /Users/username/projects/ui-components
```

2. Analyze:
```bash
cat package.json
# React, Rollup, Storybook

find . -name "*.jsx" | wc -l
# 45 components

ls -la src/components/
```

3. Create analysis:
```markdown
# Codebase Analysis

## Project Overview
**Name:** ui-components
**Type:** React component library
**Purpose:** Reusable UI components for internal projects

## Tech Stack
- **Language:** JavaScript (migrating to TypeScript)
- **Framework:** React 18
- **Build:** Rollup
- **Documentation:** Storybook

## Current State
- 45 JSX components in src/components/
- No type definitions
- PropTypes for runtime checking

## Migration Scope
All 45 components need TS conversion + type definitions
```

4. Ask objective:
"What's the priority for this migration?"
**User:** "Start with the most-used components: Button, Input, Modal, Card"

5. Deploy:
```bash
SESSION_NAME="ui-components"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm ui-components -p /Users/username/projects/ui-components
```

6. Output:
```
Codebase Analysis Complete!
Analysis saved to: .workflow/codebase-analysis.md

Project: ui-components
Path: /Users/username/projects/ui-components
Tech Stack: React + Rollup + Storybook

Objective: Migrate to TypeScript, starting with Button, Input, Modal, Card components

Session created: ui-components
Attach command copied to clipboard!
```
</action>
</example>

## Example 4: Django Application - Performance Optimization

<example>
<scenario>User has a slow Django app that needs database query optimization</scenario>
<action>

**User:** (in ~/work/django-blog) "Optimize the slow queries"

**Assistant:**

1. Analyze:
```bash
PROJECT_PATH=$(pwd)

# Check Django version
cat requirements.txt | grep Django
# Django==4.2

# Check models
ls -la blog/models/
# Post.py, Comment.py, User.py

# Check for existing profiling
ls -la | grep -i profile
```

2. Create analysis:
```markdown
# Codebase Analysis

## Project Overview
**Name:** django-blog
**Type:** Django blog application
**Purpose:** Multi-user blogging platform

## Tech Stack
- **Language:** Python 3.11
- **Framework:** Django 4.2
- **Database:** PostgreSQL
- **Cache:** Redis

## Performance Issues
Based on Django Debug Toolbar:
- N+1 queries on post list view
- Missing database indexes
- No query result caching

## Key Areas
- `blog/views.py` - View logic
- `blog/models.py` - Model definitions
```

3. Ask objective:
"Which views are the slowest?"
**User:** "Homepage and post detail page. Homepage takes 2 seconds, should be under 200ms"

4. Deploy:
```bash
SESSION_NAME="django-blog"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm django-blog -p /Users/username/work/django-blog
```

5. Output:
```
Codebase Analysis Complete!
Analysis saved to: .workflow/codebase-analysis.md

Project: django-blog
Path: /Users/username/work/django-blog
Tech Stack: Django 4.2 + PostgreSQL + Redis

Objective: Optimize homepage and post detail queries (target <200ms)

Session created: django-blog
```
</action>
</example>

## Example 5: Monorepo - New Package Addition

<example>
<scenario>User wants to add a new package to an existing monorepo</scenario>
<action>

**User:** (in ~/work/company-monorepo) "Add a new shared utils package"

**Assistant:**

1. Analyze monorepo:
```bash
PROJECT_PATH=$(pwd)

# Check workspace structure
cat package.json | grep workspaces
# packages/*

# List existing packages
ls -la packages/
# ui-components/, api-client/, shared-types/

# Check build system
cat package.json | grep -A 5 scripts
```

2. Create analysis:
```markdown
# Codebase Analysis

## Project Overview
**Name:** company-monorepo
**Type:** Monorepo with multiple packages
**Purpose:** Shared packages for internal applications

## Tech Stack
- **Language:** TypeScript
- **Build:** Turborepo + pnpm
- **Packages:** 3 existing (ui-components, api-client, shared-types)

## Monorepo Structure
- packages/ui-components/ - React components
- packages/api-client/ - API wrapper
- packages/shared-types/ - TypeScript types
- packages/ [NEW] - shared-utils (to be created)

## Build System
- Turborepo for task orchestration
- Each package has own tsconfig.json
- Shared ESLint and Prettier configs
```

3. Ask objective:
"What utilities should this package include?"
**User:** "Date formatting, string manipulation, validation helpers"

4. Deploy:
```bash
SESSION_NAME="company-monorepo"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm company-monorepo -p /Users/username/work/company-monorepo
```

5. Output:
```
Codebase Analysis Complete!
Analysis saved to: .workflow/codebase-analysis.md

Project: company-monorepo
Path: /Users/username/work/company-monorepo
Tech Stack: TypeScript + Turborepo + pnpm monorepo

Objective: Add new shared-utils package with date, string, validation utilities

Session created: company-monorepo
```
</action>
</example>

## Example 6: Legacy Code - Modernization

<example>
<scenario>User has legacy jQuery code to modernize with React</scenario>
<action>

**User:** (in ~/projects/old-dashboard) "Modernize this with React"

**Assistant:**

1. Analyze legacy code:
```bash
PROJECT_PATH=$(pwd)

# Check current stack
find . -name "*.html" | wc -l
# 15 HTML pages

find . -name "*.js" | head -5
# script.js, utils.js, ajax-handlers.js

grep -r "jQuery" . | wc -l
# 324 jQuery usage lines
```

2. Create analysis:
```markdown
# Codebase Analysis

## Project Overview
**Name:** old-dashboard
**Type:** Legacy admin dashboard
**Purpose:** Business analytics dashboard

## Current Tech Stack
- **Language:** JavaScript (ES5)
- **Library:** jQuery 2.1.4
- **Build:** None (plain HTML/CSS/JS)
- **Architecture:** Multi-page application (15 pages)

## Modernization Scope
- 15 HTML pages to convert
- 324+ jQuery usages
- No build system
- No component structure

## Proposed New Stack
- React 18 with TypeScript
- Vite for build
- React Router for SPA
- Modern state management

## Migration Strategy
Convert page by page, starting with most-used screens
```

3. Ask objective:
"Which pages should we start with?"
**User:** "Dashboard home and user management - they're used most"

4. Deploy:
```bash
SESSION_NAME="old-dashboard"
uv run --directory ${CLAUDE_PLUGIN_ROOT} python ${CLAUDE_PLUGIN_ROOT}/lib/orchestrator.py deploy-pm old-dashboard -p /Users/username/projects/old-dashboard
```

5. Output:
```
Codebase Analysis Complete!
Analysis saved to: .workflow/codebase-analysis.md

Project: old-dashboard
Path: /Users/username/projects/old-dashboard
Tech Stack: jQuery (legacy) → React + TypeScript + Vite (modernization)

Objective: Modernize dashboard home and user management pages to React

Session created: old-dashboard
```
</action>
</example>

## Analysis Patterns by Project Type

| Project Type | Key Analysis Points | Common Objectives |
|-------------|---------------------|-------------------|
| Web App | Framework, routing, state mgmt | Add features, fix bugs |
| API | Endpoints, auth, database | Optimize, add endpoints |
| Library | Exports, dependencies, build | Add utilities, TypeScript |
| Monorepo | Package structure, dependencies | Add packages, refactor |
| CLI Tool | Commands, arguments, config | Add commands, improve UX |
| Mobile Backend | APIs, push notifications, auth | Scale, add features |
