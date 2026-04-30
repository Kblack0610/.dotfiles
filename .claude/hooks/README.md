# Claude Code Hook Topology

## Stop hooks (user-global, in ~/.claude/settings.json)

| Order | File | Job | Blocks? |
|-------|------|-----|---------|
| 1 | `~/.claude/hooks/pre-stop-checks.sh` | Coordinator — fans out `stop-checks.d/*.sh` in parallel, aggregates verdict | Yes (exit 2) |
| 2 | `~/.dotfiles/.config/shared-hooks/rules-compliance-check.sh` | Session eval checklist | Yes (JSON block) |

Both read `stop_hook_active` from stdin JSON and exit clean on the second call to prevent loops.

### `stop-checks.d/` — per-check scripts

Each `*.sh` in `~/.dotfiles/.claude/hooks/stop-checks.d/` is one independent check. The coordinator fans them out in parallel and aggregates by exit code:

| Exit code | Meaning | Coordinator behavior |
|-----------|---------|----------------------|
| `0` | pass (or check not applicable) | silent |
| `1` | warn / advisory | stderr printed; coordinator still passes |
| `2` | block | coordinator exits 2; Claude is gated |
| other | block (defensive) | same as `2` |

Project-type detection lives **inside each check** (e.g. `[ -f package.json ] || exit 0`), so the coordinator stays project-agnostic. To add a check, drop `<NN>-<name>.sh` into `stop-checks.d/` and `chmod +x`. Checks run in parallel — order is informational only.

Current checks: `10-git-workflow.sh` (unpushed commits, open PRs), `20-node-checks.sh` (turbo/pnpm typecheck/lint/format/knip), `30-cargo.sh`, `40-python.sh` (ruff/mypy), `50-go.sh` (vet/golangci-lint).

The coordinator writes `status=PASS|FAIL|SKIPPED` and `note=...` to `$XDG_CACHE_HOME/claude-stop-hook/ci-result-<proj>-<date>.txt`, which `rules-compliance-check.sh` reads for eval scoring — that contract is fixed.

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
