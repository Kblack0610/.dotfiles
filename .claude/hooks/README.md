# Claude Code Hook Topology

## Stop hooks (user-global, in ~/.claude/settings.json)

One Stop entry, one entrypoint:

| File | Job |
|------|-----|
| `~/.claude/hooks/pre-stop-checks.sh` | Coordinator: runs parallel `stop-checks.d/`, then `stop-post.d/`. Single source of all Stop-time behavior. |

The coordinator runs two phases:

```
phase 1  stop-checks.d/ parallel, exit-code aggregated, may BLOCK (exit 2); skipped on a clean tree
phase 2  stop-post.d/  sequential, stdout/stderr passed through, may BLOCK (JSON or exit 2); runs ALWAYS
```

Loop guard: coordinator and any `*.d/` script reading stdin should check `stop_hook_active` and exit 0 on the second call. Coordinator passes the JSON payload to all `*.d/` children via stdin so they can self-loop-guard.

Anything that must fire on every Stop, including a pure Q&A turn with a clean tree, goes in `stop-post.d/`: it runs after the checks or after the clean-tree early exit.

### `stop-checks.d/` — content checks (parallel)

Each `*.sh` is one independent check. The coordinator fans them out in parallel and aggregates by exit code:

| Exit code | Meaning | Coordinator behavior |
|-----------|---------|----------------------|
| `0` | pass (or check not applicable) | silent |
| `1` | warn / advisory | stderr printed; coordinator still passes |
| `2` | block | coordinator exits 2; Claude is gated |
| other | block (defensive) | same as `2` |

Project-type detection lives **inside each check** (e.g. `[ -f package.json ] || exit 0`), so the coordinator stays project-agnostic. To add a check, drop `<NN>-<name>.sh` into `stop-checks.d/` and `chmod +x`. Checks run in parallel — order is informational only.

Current checks: `10-git-workflow.sh` (unpushed commits, open PRs), `20-node-checks.sh` (turbo/pnpm typecheck/lint/format/knip), `30-cargo.sh`, `40-python.sh` (ruff/mypy), `50-go.sh` (vet/golangci-lint), `60-shell-tests.sh` (the bats fast tier).

The coordinator writes `status=PASS|FAIL|SKIPPED` and `note=...` to `$XDG_CACHE_HOME/claude-stop-hook/ci-result-<session_id>.txt` (`ci-result-<proj>-<date>.txt` only when the payload has no session id) and exports the path as `CI_RESULT_FILE` to the post scripts. `95-wind-down.sh` reads it from there and never build the name themselves. Files older than a week are pruned.

### `stop-post.d/` — runs after content checks (sequential, can block)

Each `*.sh` runs sequentially with stdout/stderr piped straight to the coordinator's stdout/stderr. This means a post-check *could* block by printing a Claude Code Stop-hook JSON object on stdout (`{"decision":"block","reason":"..."}`), or by exiting 2 with a stderr message — same protocol as a top-level Stop hook. The current post-check chooses NOT to block.

Current post-checks, in order:
- `80-session-register.sh`: records the session in the session registry.
- `85-sync-plans.sh`: copies the plans this session wrote from `~/.claude/plans/` into `~/.agent/plans/<proj>/`.
- `86-focus-reconcile.sh`: at the end of a turn that changed something, checks the work was tracked on a board.
- `87-regen-anchor.sh`: regenerates the project anchor's auto block.
- `95-wind-down.sh`: fires this session's armed spin-down request (`~/.agent/spin-down/<proj>__<session_id>.request`, written by `wind-down.sh arm`), deferring while `$CI_RESULT_FILE` says FAIL. It also deletes any request older than a day, whose session ended without a Stop to consume it.

## Manual compliance audit (not Stop-time)

There is no Stop-time judge: the per-turn transcript eval was retired 2026-10-28, because a score from the last 80 lines of a transcript could not be checked and read 10/10 on most turns. The session eval is `agentctl-session-outcomes` (nightly, from transcript structure, git and gh) plus the `fleet-bench` scorecard in the daily briefing. A manual rules-compliance LLM judge stays available on demand:

| Surface | Invocation | Backing script |
|---------|-----------|----------------|
| Claude slash command | `/my:judge` | `~/.claude/hooks/llm-judge.sh` (+ `lib/`) |
| Codex skill | `/llm-judge` | `~/.dotfiles/.config/codex/skills/llm-judge/judge.sh` |

These read the project transcript and print a compliance audit. They are not wired into Stop. Configuration lives at `~/.dotfiles/.config/llm-judge/`.

## SessionStart hooks (user-global)

| File | Job |
|------|-----|
| `~/.dotfiles/.config/shared-hooks/session-preflight.sh` | Inject plans/lessons/git context |

## PreToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| Bash | `~/.claude/hooks/block-pip.sh` | Block `pip install`, suggest `uv` |
| Grep, Glob, Bash | `~/.claude/hooks/block-root-search.sh` | Deny a recursive search whose root holds a network mount (`/`, `/mnt`), unless it stays on one filesystem |
| Read | `~/.claude/hooks/large-file-warning.sh` | Warn on large file reads |
| Agent\|Task\|Workflow | `~/.claude/hooks/spawn-watch.sh` | Ping the human when one session passes 40/80/160 spawns. Alert only: always exits 0, never denies |

## PostToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/board-observe.sh` | Record a sprint-board stage transition when the board is edited |
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/ai-comment-guard.sh` | Warn on AI-tell comments in what was just written |
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/memory-index-guard.sh` | Warn when an auto-memory `MEMORY.md` passes 8 KB or has a line over 200 chars |

## File layout

- `~/.claude/hooks/` is hard-linked to `~/.dotfiles/.claude/hooks/` (same inodes via stow).
- `~/.dotfiles/.config/shared-hooks/` holds hooks shared across runtimes (Claude Code + Codex).
- Project repos should NOT have their own `pre-stop-checks.sh` — the user-global one handles all project types. If a project needs custom CI, add a case to the global hook.

## Loop-guard contract

Every Stop hook that can exit non-zero MUST check `stop_hook_active` from stdin and exit 0 on the second call. Without this, the agent loops forever when it can't fix the failure (e.g., plan mode).
