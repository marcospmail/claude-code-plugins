---
name: bump-version
description: Bump the Yato plugin version in .claude-plugin/plugin.json. Use this skill whenever you need to update the plugin version number, increment version, or release a new version.
user-invocable: true
---

# Bump Plugin Version

<context>
Yato's plugin version is in `.claude-plugin/plugin.json` under the `"version"` field (currently "3.8.1").
This follows semantic versioning (semver): MAJOR.MINOR.PATCH
</context>

<instructions>
## How to Bump Version

1. Read `.claude-plugin/plugin.json` to get current version
2. Determine increment type:
   - **PATCH** (x.x.N): Bug fixes, minor updates, documentation
   - **MINOR** (x.N.0): New features, backwards-compatible changes
   - **MAJOR** (N.0.0): Breaking changes, major refactors
3. Update the `"version"` field in `.claude-plugin/plugin.json`
4. Commit the change

## Important Notes

- **DO bump**: `.claude-plugin/plugin.json` → `"version"` field
- **DO NOT bump**: `pyproject.toml` version (that's the Python package version, separate concern)

### Example

User: "Bump version for bug fix"
→ Read current: "3.8.1"
→ Increment patch: "3.8.2"
→ Update `.claude-plugin/plugin.json`
</instructions>
