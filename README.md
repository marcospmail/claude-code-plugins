# Claude Code Plugins

A collection of Claude Code plugins for enhanced development workflows.

## Plugins

| Plugin | Description |
|--------|-------------|
| [yato](./plugins/yato/) | Yet Another Tmux Orchestrator - Multi-agent orchestration with parallel Claude instances in tmux |

## Installation

### From GitHub (marketplace)

```bash
/plugin marketplace add marcospmail/claude-code-plugins
/plugin install yato@claude-code-plugins
```

### From local directory

```bash
/plugin marketplace add /path/to/claude-code-plugins
/plugin install yato@claude-code-plugins
```

## Structure

```
claude-code-plugins/
├── .claude-plugin/
│   └── marketplace.json        # Marketplace manifest
├── plugins/
│   └── yato/                   # Yato plugin
│       ├── .claude-plugin/
│       │   └── plugin.json     # Plugin manifest
│       ├── skills/             # Claude Code skills
│       ├── hooks/              # Claude Code hooks
│       ├── lib/                # Python modules
│       └── ...
└── README.md
```
