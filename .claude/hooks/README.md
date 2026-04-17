# Claude Code Hook Topology

## Stop hooks (user-global, in ~/.claude/settings.json)

| Order | File | Job | Blocks? |
|-------|------|-----|---------|
| 1 | `~/.claude/hooks/pre-stop-checks.sh` | CI checks (typecheck, lint, format) | Yes (exit 2) |
| 2 | `~/.dotfiles/.config/shared-hooks/rules-compliance-check.sh` | Session eval checklist | Yes (JSON block) |

Both read `stop_hook_active` from stdin JSON and exit clean on the second call to prevent loops.

## SessionStart hooks (user-global)

| File | Job |
|------|-----|
| `~/.claude/setup-personal-mcp.sh` | Wire up personal MCP servers |
| `~/.dotfiles/.config/shared-hooks/session-preflight.sh` | Inject plans/lessons/git context |

## PreToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| Bash | `~/.claude/hooks/block-pip.sh` | Block `pip install`, suggest `uv` |
| Read | `~/.claude/hooks/large-file-warning.sh` | Warn on large file reads |

## File layout

- `~/.claude/hooks/` is hard-linked to `~/.dotfiles/.claude/hooks/` (same inodes via stow).
- `~/.dotfiles/.config/shared-hooks/` holds hooks shared across runtimes (Claude Code + Codex).
- Project repos should NOT have their own `pre-stop-checks.sh` — the user-global one handles all project types. If a project needs custom CI, add a case to the global hook.

## Loop-guard contract

Every Stop hook that can exit non-zero MUST check `stop_hook_active` from stdin and exit 0 on the second call. Without this, the agent loops forever when it can't fix the failure (e.g., plan mode).
