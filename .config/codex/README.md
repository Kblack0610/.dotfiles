# Codex and opencode config

`sync-ai-global-config.sh` is the one writer of the Codex, opencode and Gemini homes. Run it after changing anything here, in the rulesync source, or in `~/.claude/skills` (`codex-sync` is an alias; the post-commit hook runs it for a commit in the main checkout that changes this script, never in a worktree).

## What each tool gets

| Piece | Claude Code | Codex (0.164) | opencode |
|---|---|---|---|
| Rules | `~/.claude/CLAUDE.md` (stow) | `~/.codex/AGENTS.md`, from rulesync plus the sections spliced from CLAUDE.md | `~/.config/opencode/AGENTS.md`, the same file |
| Skills | `~/.claude/skills` (stow) | `~/.codex/skills/<name>`, one link per Claude skill (`sync-codex-home.sh`) | reads `~/.claude/skills` itself |
| Agents and commands | `~/.claude/agents`, `~/.claude/commands` | none: Codex has no agent definitions or command files | mirrored by `sync-opencode-claude-assets.sh` |
| Session preflight | SessionStart hook | SessionStart hook in `~/.codex/hooks.json` | `plugins/preflight.ts` (private repo) |
| Shell guards (block-poll, block-pip, block-pkill-f, forge-guard, checkout-guard, block-root-search) | PreToolUse hooks | PreToolUse `Bash` hooks in `~/.codex/hooks.json` | none |
| Queue item close check | Stop checks | Stop hook `codex-item-stop.sh`: a fleet run whose item is still running with no PR gets one more turn to close it | none |
| Other hooks (plan gates, compact-prep, ask-settle, spawn-watch, edit guards) | yes | none: they read Claude transcripts or Claude-only tools | none |
| Model and project docs | settings.json | `config.owned.toml` here: its keys (`model`, `project_doc_fallback_filenames`) head `~/.codex/config.toml` and replace the human's copies; a repo's CLAUDE.md is read only where it has no AGENTS.md | n/a |
| MCP servers | each repo's `.mcp.json` | user scope, from rulesync (`codex mcp list`) | user scope, from rulesync (`opencode.json` `mcp`) |

`hooks.json` here is the source for `~/.codex/hooks.json`: `$HOME` is filled in, and the sync refuses to write it when a command names a script that is not there (`tests/unit/codex_home_sync.bats`). Codex runs a hook only once it is trusted, and a changed `hooks.json` is untrusted again: an interactive `codex` asks, and fleet launches (`fleet-dispatch`) pass `--dangerously-bypass-hook-trust`.

## Troubleshooting

| Symptom | Cause and fix |
|---|---|
| `Codex hooks: not written, these scripts are not there` | A hook in `hooks.json` names a moved or deleted script. Fix the path here; the old `~/.codex/hooks.json` is left in place until then. |
| A skill is missing in Codex | It has no `SKILL.md` at the top of its dir in `~/.claude/skills`, or `~/.codex/skills/<name>` is a real directory (the sync never links over one). |
| `rmcp_client` or `codex_hooks` in `config.toml` | Left by an older sync. The current sync drops both from `[features]`. |
| `codex exec` logs HTTP 401 / `token_expired` at startup | Not an MCP server: a Codex app-server daemon (`codex app-server ... --managed-daemon`) started before the last `codex login` still holds the old token. Restart it (quit and reopen the Codex app, or end that process); agents do not touch auth state. |
| Hooks stopped firing after a sync | `hooks.json` changed, so Codex no longer trusts it. Open `codex` once and trust the hooks; fleet runs bypass trust. |
| `Codex is ignoring N unrecognized configuration settings` | `type` and `description` keys on `[mcp_servers.*]` from rulesync. The sync strips them from the managed block. |
