# YAWF Existing Project - Reference

## Codebase Analysis Process

### Detection Commands

**Package Managers:**
```bash
# Node.js/JavaScript
test -f package.json && cat package.json | jq '.dependencies, .devDependencies'
test -f yarn.lock && echo "Uses Yarn"
test -f pnpm-lock.yaml && echo "Uses pnpm"

# Python
test -f requirements.txt && cat requirements.txt
test -f pyproject.toml && cat pyproject.toml | grep -A 10 "\[project\]"
test -f setup.py && cat setup.py

# Ruby
test -f Gemfile && cat Gemfile
test -f Gemfile.lock && head -20 Gemfile.lock

# Go
test -f go.mod && cat go.mod

# Java
test -f pom.xml && cat pom.xml | grep -A 5 "dependencies"
test -f build.gradle && cat build.gradle

# Rust
test -f Cargo.toml && cat Cargo.toml
```

**Project Structure:**
```bash
# Get directory tree (excluding common noise)
find . -maxdepth 3 -type d \
  | grep -v node_modules \
  | grep -v .git \
  | grep -v __pycache__ \
  | grep -v .next \
  | grep -v dist \
  | grep -v build \
  | head -50

# Count files by type
find . -type f | sed 's/.*\.//' | sort | uniq -c | sort -rn | head -20
```

**Configuration Files:**
```bash
# Check for common config files
ls -la | grep -E "\.config|\.rc|\.json|\.yaml|\.toml|\.ini"

# Check for environment files
ls -la | grep -E "\.env"
```

### Analysis Output Structure

**Template for .workflow/codebase-analysis.md:**

```markdown
# Codebase Analysis
*Generated: [DATE]*

## Project Overview
**Name:** [Project name from package.json or directory]
**Type:** [Web app, API, CLI tool, library, etc.]
**Purpose:** [What the project does]

## Project Structure
```
project-root/
├── src/              # Source code
│   ├── components/   # React components
│   ├── pages/        # Page components
│   └── utils/        # Utility functions
├── public/           # Static assets
├── tests/            # Test files
└── package.json      # Dependencies
```

## Tech Stack

### Core Technologies
- **Language:** [JavaScript/TypeScript/Python/etc.]
- **Runtime:** [Node.js 20, Python 3.11, etc.]
- **Framework:** [Next.js 14, FastAPI, Rails, etc.]

### Dependencies
**Production:**
- [key-library-1] - [purpose]
- [key-library-2] - [purpose]

**Development:**
- [dev-tool-1] - [purpose]
- [dev-tool-2] - [purpose]

## Architecture

### Pattern
[MVC, MVVM, Clean Architecture, Microservices, Monolith, etc.]

### Data Flow
[How data moves through the application]

### State Management
[Redux, Context API, Zustand, none, etc.]

## Key Modules

### [Module Name 1]
**Path:** `src/[path]`
**Responsibility:** [What it does]
**Key Files:**
- `[file1.js]` - [purpose]
- `[file2.js]` - [purpose]

### [Module Name 2]
**Path:** `src/[path]`
**Responsibility:** [What it does]

## Patterns & Conventions

### Code Style
- **Formatting:** [Prettier, ESLint, Black, etc.]
- **Naming:** [camelCase, snake_case, PascalCase for what]
- **File Organization:** [How files are organized]

### Architecture Patterns
- [Pattern 1]: [Where it's used]
- [Pattern 2]: [Where it's used]

### Testing Approach
- **Framework:** [Jest, Pytest, RSpec, etc.]
- **Coverage:** [Current coverage if available]
- **Test Location:** [Where tests live]

## Entry Points

### Development
```bash
[Command to start dev server]
```

### Production
```bash
[Command to build and run in production]
```

### Testing
```bash
[Command to run tests]
```

## API Surface

### Endpoints (if applicable)
- `GET /api/[endpoint]` - [purpose]
- `POST /api/[endpoint]` - [purpose]

### CLI Commands (if applicable)
- `[command]` - [purpose]

## Database (if applicable)
- **Type:** [PostgreSQL, MongoDB, SQLite, etc.]
- **ORM/ODM:** [Prisma, Mongoose, SQLAlchemy, etc.]
- **Schema Location:** [Where schema is defined]

## Configuration
- **Environment Variables:** [.env file, which variables are needed]
- **Config Files:** [List key config files]

## Build System
- **Bundler:** [Webpack, Vite, Rollup, esbuild, etc.]
- **Build Command:** `[build command]`
- **Output:** [Where build artifacts go]

## Notes
[Any special considerations, gotchas, or important context]
```

## Session Generation

### Session Name Algorithm

```bash
# Get project directory name
PROJECT_NAME=$(basename "$PROJECT_PATH")

# Convert to lowercase kebab-case
SESSION_NAME=$(echo "$PROJECT_NAME" | tr '[:upper:]' '[:lower:]' | tr '_' '-' | tr ' ' '-')
```

**Examples:**
- `My_Project` → `my-project`
- `UserAuthService` → `userauthservice` (may want to manually adjust)
- `task templates` → `task-templates`

## User Interaction

### Asking for Objectives

**Good prompts:**
- "What would you like to work on in this project?"
- "What feature or improvement are you planning?"
- "Are you fixing a bug, adding a feature, or refactoring?"

**Capture specifics:**
- Feature descriptions
- Bug reports or issue numbers
- Refactoring goals
- Performance targets

### Passing Context to PM

When deploying the PM, you can pass the analysis and objectives:

```bash
# Deploy PM
python3 ~/dev/tools/yato/lib/orchestrator.py deploy-pm "$SESSION_NAME" -p "$PROJECT_PATH"

# Send analysis context
sleep 5
~/dev/tools/yato/bin/send-message.sh "$SESSION_NAME:0" \
  "Project analysis complete. See .workflow/codebase-analysis.md for details. User objective: [USER_OBJECTIVE]"
```

## Troubleshooting

### Analysis Takes Too Long

**Issue:** Large codebase causes analysis timeout

**Solution:**
```bash
# Limit analysis depth
find . -maxdepth 2 -type d | grep -v node_modules

# Focus on specific areas
ls -la src/
ls -la app/
```

### Can't Determine Project Type

**Issue:** No clear package manager or framework indicators

**Solution:**
1. Check file extensions
2. Look for import statements
3. Check shebang lines in executables
4. Ask user directly: "What framework/language is this project using?"

### Workflow Directory Creation Fails

**Issue:** `.workflow/` directory can't be created

**Solution:**
```bash
# Check permissions
ls -la .

# Create with sudo if needed
sudo mkdir -p .workflow

# Or use /tmp as fallback
mkdir -p /tmp/workflow-$(basename $PWD)
```

## Integration Patterns

### With GitHub Issues

```bash
# Check for GitHub issues
gh issue list --limit 10

# Add to analysis
echo "## Open Issues" >> .workflow/codebase-analysis.md
gh issue list --limit 5 >> .workflow/codebase-analysis.md
```

### With Documentation

```bash
# Check for docs
test -d docs && ls -la docs/
test -f README.md && echo "Has README"
test -f CONTRIBUTING.md && echo "Has contribution guide"

# Include in analysis
cat README.md >> .workflow/codebase-analysis.md
```

## Best Practices

1. **Always analyze before asking** - Understand the project before asking what to do
2. **Create detailed analysis** - More context helps the PM make better decisions
3. **Save analysis for reference** - The PM and developers will need this
4. **Ask specific questions** - Guide user to provide clear objectives
5. **Verify session doesn't exist** - Check `tmux list-sessions` first
6. **Document assumptions** - Note what you inferred vs. what's explicit
