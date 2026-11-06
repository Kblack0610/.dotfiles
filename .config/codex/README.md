# Codex and opencode config

`sync-ai-global-config.sh` is the one writer of the Codex, opencode and Gemini homes. Run it after changing anything here, in the rulesync source, or in `~/.claude/skills` (`codex-sync` is an alias; the post-commit hook runs it when the rulesync source changes).

## What each tool gets

| Piece | Claude Code | Codex (0.164) | opencode |
|---|---|---|---|
| Rules | `~/.claude/CLAUDE.md` (stow) | `~/.codex/AGENTS.md`, from rulesync plus the sections spliced from CLAUDE.md | `~/.config/opencode/AGENTS.md`, the same file |
| Skills | `~/.claude/skills` (stow) | `~/.codex/skills/<name>`, one link per Claude skill (`sync-codex-home.sh`) | reads `~/.claude/skills` itself |
| Agents and commands | `~/.claude/agents`, `~/.claude/commands` | none: Codex has no agent definitions or command files | mirrored by `sync-opencode-claude-assets.sh` |
| Session preflight | SessionStart hook | SessionStart hook in `~/.codex/hooks.json` | `plugins/preflight.ts` (private repo) |
| Shell guards (block-poll, block-pip, block-root-search) | PreToolUse hooks | PreToolUse `Bash` hooks in `~/.codex/hooks.json` | none |
| Other hooks (Stop checks, plan gates, compact-prep, ask-settle, spawn-watch, edit guards) | yes | none: they read Claude transcripts or Claude-only tools | none |
| MCP servers | each repo's `.mcp.json` | user scope, from rulesync (`codex mcp list`) | user scope, from rulesync (`opencode.json` `mcp`) |

`hooks.json` here is the source for `~/.codex/hooks.json`: `$HOME` is filled in, and the sync refuses to write it when a command names a script that is not there (`tests/unit/codex_home_sync.bats`).

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Codex hooks: not written, these scripts are not there` | A hook in `hooks.json` names a moved or deleted script. Fix the path here; the old `~/.codex/hooks.json` is left in place until then. |
| A skill is missing in Codex | It has no `SKILL.md` at the top of its dir in `~/.claude/skills`, or `~/.codex/skills/<name>` is a real directory (the sync never links over one). |
| `rmcp_client` or `codex_hooks` in `config.toml` | Left by an older sync. The current sync drops both from `[features]`. |
