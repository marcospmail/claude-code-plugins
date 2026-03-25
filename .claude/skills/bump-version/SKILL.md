---
name: bump-version
description: Bump plugin versions in .claude-plugin/plugin.json and marketplace metadata version in .claude-plugin/marketplace.json. Use this skill whenever you need to update version numbers, increment versions, or release a new version.
user-invocable: true
---

# Bump Version

<context>
Plugin versions live in each plugin's `.claude-plugin/plugin.json` under the `"version"` field.
The marketplace metadata version is in `.claude-plugin/marketplace.json` under `"metadata"."version"`.
Both follow semantic versioning (semver): MAJOR.MINOR.PATCH
</context>

<instructions>
## How to Bump Version

1. Read the relevant `plugin.json` or `marketplace.json` to get the current version
2. Determine increment type:
   - **PATCH** (x.x.N): Bug fixes, minor updates, documentation
   - **MINOR** (x.N.0): New features, backwards-compatible changes
   - **MAJOR** (N.0.0): Breaking changes, major refactors
3. Update the `"version"` field
4. Commit the change

## Important Notes

- `plugin.json` is the single source of truth for plugin versions
- `marketplace.json` metadata version tracks marketplace-level changes (new plugins added, structural changes)
- `marketplace.json` plugin entries do NOT include version fields
</instructions>
