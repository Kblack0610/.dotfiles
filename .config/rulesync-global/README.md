# Rulesync Global Source

This directory is the dotfiles-managed source of truth for shared AI assistant rules and MCP configuration.

`rulesync generate` runs here in a temporary staging directory. The generated files are then merged into the real global tool locations by `.config/codex/sync-ai-global-config.sh`.

The sync script intentionally does not trust Rulesync global mode to write directly into live home-directory configs. It stages output locally first, then merges only the shared slices:

- shared root rule files
- shared MCP server definitions

Tool-specific auth, state, model selection, permissions, hooks, and extra MCP entries remain owned by each tool's native config.
