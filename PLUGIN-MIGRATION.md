# Plugin Migration Plan

Files to move into `tmux-orchestrator/` to make it a proper Claude Code plugin.

## Current Location → Target Location

### Skills (move from dotfiles)

| Current Location (MOVE FROM) | Target Location (MOVE TO) |
|------------------------------|---------------------------|
| `/Users/personal/dev/dotfiles/claude-code/skills/yawf-resume/` | `tmux-orchestrator/skills/yawf-resume/` |
| `/Users/personal/dev/dotfiles/claude-code/skills/yawf-existing-project/` | `tmux-orchestrator/skills/yawf-existing-project/` |
| `/Users/personal/dev/dotfiles/claude-code/skills/yawf-new-project/` | `tmux-orchestrator/skills/yawf-new-project/` |

### Agents (move from dotfiles)

| Current Location (MOVE FROM) | Target Location (MOVE TO) |
|------------------------------|---------------------------|
| `/Users/personal/dev/dotfiles/claude-code/agents/tmux-meta-agent.md` | `tmux-orchestrator/agents/tmux-meta-agent.md` |

### Commands (move from user global)

| Current Location (MOVE FROM) | Target Location (MOVE TO) |
|------------------------------|---------------------------|
| `/Users/personal/.claude/commands/parse-prd-to-tasks.md` | `tmux-orchestrator/commands/parse-prd-to-tasks.md` |

### New Files to Create

| File | Purpose |
|------|---------|
| `.claude-plugin/plugin.json` | Plugin manifest with name, version, description |

## Final Plugin Structure

```
tmux-orchestrator/
├── .claude-plugin/
│   └── plugin.json              # NEW - Plugin manifest
├── skills/
│   ├── yawf-resume/             # MOVE from dotfiles
│   │   └── SKILL.md
│   ├── yawf-existing-project/   # MOVE from dotfiles
│   │   ├── SKILL.md
│   │   ├── reference.md
│   │   └── examples.md
│   └── yawf-new-project/        # MOVE from dotfiles
│       └── SKILL.md
├── commands/
│   └── parse-prd-to-tasks.md    # MOVE from user global
├── agents/
│   ├── tmux-meta-agent.md       # MOVE from dotfiles
│   ├── developer.md             # Already here
│   ├── pm.md                    # Already here
│   └── qa.md                    # Already here
├── bin/                         # Already here
├── lib/                         # Already here
├── templates/                   # Already here
├── config/                      # Already here
├── CLAUDE.md                    # Already here
└── README.md                    # Already here
```

## After Migration

1. Remove moved files from dotfiles
2. Update any symlinks if needed
3. Commands will be namespaced as `/tmux-orchestrator:yawf-resume`, etc.
