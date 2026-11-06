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

Loop guard: coordinator and any `*.d/` script reading stdin should check `stop_hook_active` and exit 0 on the second call. Coordinator passes the JSON payload to the `stop-post.d/` children via stdin so they can self-loop-guard. The `stop-checks.d/` children run with no stdin; they get the payload's session id as `STOP_SESSION_ID`.

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

Current checks: `10-git-workflow.sh` (unpushed commits, which only warn while a background run of this session is live, read as a process holding its `tasks/<id>.output` open; open PRs), `20-node-checks.sh` (turbo/pnpm typecheck/lint/format/knip), `30-cargo.sh`, `40-python.sh` (ruff/mypy), `50-go.sh` (vet/golangci-lint), `60-shell-tests.sh` (the bats fast tier).

The coordinator writes `status=PASS|FAIL|SKIPPED` and `note=...` to `$XDG_CACHE_HOME/claude-stop-hook/ci-result-<session_id>.txt` (`ci-result-<proj>-<date>.txt` only when the payload has no session id) and exports the path as `CI_RESULT_FILE` to the post scripts. `95-wind-down.sh` reads it from there and never builds the name itself. Files older than a week are pruned.

### `stop-post.d/` — runs after content checks (sequential, can block)

Each `*.sh` runs sequentially with stdout/stderr piped straight to the coordinator's stdout/stderr. This means a post-check *could* block by printing a Claude Code Stop-hook JSON object on stdout (`{"decision":"block","reason":"..."}`), or by exiting 2 with a stderr message - same protocol as a top-level Stop hook. Most post-checks never block; `86-focus-reconcile.sh` and `88-ask-filed.sh` block a turn once, with the instruction to follow.

Current post-checks, in order:
- `80-session-register.sh`: records the session in the session registry.
- `85-sync-plans.sh`: copies the plans this session wrote from `~/.claude/plans/` into `~/.agent/plans/<proj>/`.
- `86-focus-reconcile.sh`: at the end of a turn that changed something, checks the work was tracked: an agent-queue item (`$AGENT_QUEUE_ITEM`, or an `agent-queue add|move|set` or `agent-land` call), a board write, or a Focus item in progress.
- `87-regen-anchor.sh`: regenerates the project anchor's auto block.
- `88-ask-filed.sh`: when an attended session ends its turn asking the human something and owns no pending ask, blocks once with the instruction to file it with `agent-ask post`.
- `90-session-spend.sh`: when an attended session that is not a queue session passes `CLAUDE_SESSION_ALERT_USD` ($60) of OTel cost in Prometheus, pages once at 1x, 2x, 4x and so on. Alert only: always exits 0 and prints nothing.
- `95-wind-down.sh`: fires this session's armed spin-down request (`~/.agent/spin-down/<proj>__<session_id>.request`, written by `wind-down.sh arm`), deferring while `$CI_RESULT_FILE` says FAIL. A fired request stays as `.fired`, which `fleet-dispatch restore` reads to leave that conversation closed, and the next prompt in that session clears it. It also deletes any request or `.fired` older than a day.

## Session evaluation (not Stop-time)

There is no Stop-time judge. The session eval is `agentctl-session-outcomes` (nightly, from transcript structure, git and gh) plus the `fleet-bench` scorecard in the daily briefing.

## SessionStart hooks (user-global)

| File | Job |
|------|-----|
| `~/.dotfiles/.config/shared-hooks/session-preflight.sh` | Inject plans/lessons/git context |

## PreToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| Bash | `~/.claude/hooks/block-pip.sh` | Block `pip install`, suggest `uv` |
| Bash | `~/.claude/hooks/block-poll.py` | Deny `gh run watch`, a foreground `until`/`while`/`for` loop that sleeps (a wait), and a foreground read of a background task's `tasks/<id>.output` while a process still holds it open (the run is live): it points at `run_in_background`, Monitor and the completion notice. A background loop, a script file, quoted text and a read after the run exits are allowed |
| Grep, Glob, Bash | `~/.claude/hooks/block-root-search.sh` | Deny a recursive search whose root holds a network mount (`/`, `/mnt`), unless it stays on one filesystem |
| Read | `~/.claude/hooks/large-file-warning.sh` | Warn on large file reads |
| Edit\|Write\|MultiEdit\|NotebookEdit\|EnterPlanMode | `~/.claude/hooks/manual-mode-investigate.sh` | In manual (default) permission mode, deny: that mode is investigate-only. Also on UserPromptSubmit, where it injects the investigate posture |
| ExitPlanMode | `~/.claude/hooks/plan-standard.sh` | Deny a plan that misses the sections `~/.local/src/docs/planning.md` requires for this project's type, naming each gap. The same hook on UserPromptSubmit injects those sections in plan mode. Fails open when the doc is missing |
| Agent\|Task\|Workflow | `~/.claude/hooks/spawn-watch.sh` | Ping the human when one session passes 40/80/160 spawns. Alert only: always exits 0, never denies |

A deny (PreToolUse) or block (Stop) reason starts with `<hook-name>: `. session-outcomes counts each denial under that name in the outcome row's `guards`, which is how a guard's effect is counted; a reason with no name lead is invisible to it (`tests/unit/session_outcomes.bats` "guards").

## PostToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/ai-comment-guard.sh` | Warn on AI-tell comments in what was just written |
| ExitPlanMode | `~/.claude/hooks/plan-approved.sh` | Record the approved plan in `~/.agent/plans/approved.jsonl`, so `fleet-dispatch reap` can queue its open phases once its session is gone |
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/context-budget-guard.sh` | Warn when an always-loaded file passes its budget: `MEMORY.md` 8 KB (or a line over 200 chars), global `CLAUDE.md` 20 KB, repo root `CLAUDE.md`/`AGENTS.md` 12 KB |

## Token usage tracking

`agent-usage tokens snapshot` runs nightly as the first step of `day-log nightly` (agentctl `token-usage`, 03:40, in `~/.dotfiles-private/.config/agentctl/agents/`) and writes one JSON per finished local day to `~/.agent/token-usage/<date>.json`. It has no scanner of its own; it joins the two counted tools:

| Number | Owner |
|--------|-------|
| Responses, input, cache write, cache read, output; context per response; tool output and its carried cost by project, tool and command head; `long_runs` | `claude-recall tool-output` |
| Cost (registry), sessions, merged PRs and cost per merged PR, start context (first-turn median), compactions, tokens by model, sessions by kind and account | `agent-usage burn` |

- `carried_share` is carried tool output (about 4 chars a token) over all context read; `carried_x` is how many times its own size a tool result is re-read before a compaction drops it.
- `long_runs` lists the stretches between compactions that ran 150 or more responses (`claude-recall tool-output --long-turns N` to change it), top 10 by carried cost.
- `agent-usage tokens line` prints the one-line row that `day-log` and the `fleet-bench` scorecard show; `tokens json --date D` is the day's snapshot, which `day-log` copies into `.agents`.
- `agent-usage tokens check` compares context per response, carried share and the start-context median with the median of the 7 days before. It exits 1 past 25% either way, and 2 when the newest snapshot is more than 2 days old. The Sentinel watch `token-usage-drift` runs it every 6 hours. It only alerts; nothing caps or slows a session.

| Symptom | Cause | Fix |
|---------|-------|-----|
| The watch says the nightly run stopped | No snapshot in 2 days | `agentctl status token-usage`; run `agent-usage tokens snapshot` by hand for each missing day (`--date D`) |
| A row ends in "N source errors" | burn or one recall query failed; the rest of the day is still written | `jq .errors ~/.agent/token-usage/<date>.json` names the source |
| The row reads "unreadable" | `claude-recall tool-output` gave no totals, so the day has no numbers | Run the recall command from `.errors` by hand; re-run the snapshot for that day |
| The check says "baseline N days" | Fewer than 3 earlier snapshots | Wait, or backfill with `--date` |

## File layout

- `~/.claude/hooks/` is a stow symlink to `~/.dotfiles/.claude/hooks/`.
- `~/.dotfiles/.config/shared-hooks/` holds hooks shared across runtimes (Claude Code + Codex).
- Project repos should NOT have their own `pre-stop-checks.sh` — the user-global one handles all project types. If a project needs custom CI, add a case to the global hook.

## Loop-guard contract

Every Stop hook that can exit non-zero MUST check `stop_hook_active` from stdin and exit 0 on the second call. Without this, the agent loops forever when it can't fix the failure (e.g., plan mode).
