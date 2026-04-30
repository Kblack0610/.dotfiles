# Claude Code Hook Topology

## Stop hooks (user-global, in ~/.claude/settings.json)

One Stop entry, one entrypoint:

| File | Job |
|------|-----|
| `~/.claude/hooks/pre-stop-checks.sh` | Coordinator — runs `stop-pre.d/`, then parallel `stop-checks.d/`, then `stop-post.d/`. Single source of all Stop-time behavior. |

The coordinator runs three phases:

```
phase 1  stop-pre.d/   sequential, non-blocking, runs ALWAYS (incl. no-changes)
phase 2  stop-checks.d/ parallel, exit-code aggregated, may BLOCK (exit 2)
phase 3  stop-post.d/  sequential, stdout/stderr passed through, may BLOCK (JSON or exit 2)
```

Loop guard: coordinator and any `*.d/` script reading stdin should check `stop_hook_active` and exit 0 on the second call. Coordinator passes the JSON payload to all `*.d/` children via stdin so they can self-loop-guard.

### `stop-pre.d/` — runs on every Stop, even no-changes

Each `*.sh` runs sequentially before the no-changes early exit. Exit-code semantics: 0 = ok, anything else = warn (logged, never blocks). Use this phase for snapshots, telemetry, or anything that must fire on pure Q&A turns.

Current pre-checks:
- `10-entire-snapshot.sh` — runs `entire hooks claude-code stop` if `entire` is on PATH.

### `stop-checks.d/` — content checks (parallel)

Each `*.sh` is one independent check. The coordinator fans them out in parallel and aggregates by exit code:

| Exit code | Meaning | Coordinator behavior |
|-----------|---------|----------------------|
| `0` | pass (or check not applicable) | silent |
| `1` | warn / advisory | stderr printed; coordinator still passes |
| `2` | block | coordinator exits 2; Claude is gated |
| other | block (defensive) | same as `2` |

Project-type detection lives **inside each check** (e.g. `[ -f package.json ] || exit 0`), so the coordinator stays project-agnostic. To add a check, drop `<NN>-<name>.sh` into `stop-checks.d/` and `chmod +x`. Checks run in parallel — order is informational only.

Current checks: `10-git-workflow.sh` (unpushed commits, open PRs), `20-node-checks.sh` (turbo/pnpm typecheck/lint/format/knip), `30-cargo.sh`, `40-python.sh` (ruff/mypy), `50-go.sh` (vet/golangci-lint).

The coordinator writes `status=PASS|FAIL|SKIPPED` and `note=...` to `$XDG_CACHE_HOME/claude-stop-hook/ci-result-<proj>-<date>.txt`, which `stop-post.d/90-eval-gate.sh` reads.

### `stop-post.d/` — runs after content checks (sequential, can block)

Each `*.sh` runs sequentially with stdout/stderr piped straight to the coordinator's stdout/stderr. This means a post-check can block by printing a Claude Code Stop-hook JSON object on stdout (`{"decision":"block","reason":"..."}`), or by exiting 2 with a stderr message — same protocol as a top-level Stop hook.

Current post-checks:
- `90-eval-gate.sh` — emits a 3–4 line JSON-block once per turn so the AI self-evaluates. Skips pure Q&A. Reads CI status from the file the content-check phase writes.

## Manual compliance audit (not Stop-time)

Separate from the automated Stop-time eval-gate, there's a manual rules-compliance LLM judge available on demand:

| Surface | Invocation | Backing script |
|---------|-----------|----------------|
| Claude slash command | `/my:judge` | `~/.claude/hooks/llm-judge.sh` (+ `lib/`) |
| Codex skill | `/llm-judge` | `~/.dotfiles/.config/codex/skills/llm-judge/judge.sh` |

These read the project transcript and produce a deeper compliance audit than the Stop-hook eval-gate. They're **not** wired into Stop — invoke when you want them. Configuration lives at `~/.dotfiles/.config/llm-judge/`.

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
