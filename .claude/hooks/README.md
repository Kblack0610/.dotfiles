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

The coordinator writes `status=PASS|FAIL|SKIPPED` and `note=...` to `$XDG_CACHE_HOME/claude-stop-hook/ci-result-<session_id>.txt` (`ci-result-<proj>-<date>.txt` only when the payload has no session id) and exports the path as `CI_RESULT_FILE` to the post scripts. `95-wind-down.sh` reads it from there and never build the name themselves. Files older than a week are pruned.

### `stop-post.d/` — runs after content checks (sequential, can block)

Each `*.sh` runs sequentially with stdout/stderr piped straight to the coordinator's stdout/stderr. This means a post-check *could* block by printing a Claude Code Stop-hook JSON object on stdout (`{"decision":"block","reason":"..."}`), or by exiting 2 with a stderr message — same protocol as a top-level Stop hook. The current post-check chooses NOT to block.

Current post-checks, in order:
- `80-session-register.sh`: records the session in the session registry.
- `85-sync-plans.sh`: copies the plans this session wrote from `~/.claude/plans/` into `~/.agent/plans/<proj>/`.
- `86-focus-reconcile.sh`: at the end of a turn that changed something, checks the work was tracked: an agent-queue item (`$AGENT_QUEUE_ITEM`, or an `agent-queue add|move|set` or `agent-land` call), a board write, or a Focus item in progress.
- `87-regen-anchor.sh`: regenerates the project anchor's auto block.
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
| Bash | `~/.claude/hooks/block-poll.py` | Deny `gh run watch`, and a foreground `until`/`while`/`for` loop that sleeps (a wait): it points at `run_in_background` and the completion notice. A background loop, a script file and quoted text are allowed |
| Grep, Glob, Bash | `~/.claude/hooks/block-root-search.sh` | Deny a recursive search whose root holds a network mount (`/`, `/mnt`), unless it stays on one filesystem |
| Read | `~/.claude/hooks/large-file-warning.sh` | Warn on large file reads |
| Edit\|Write\|MultiEdit\|NotebookEdit\|EnterPlanMode | `~/.claude/hooks/manual-mode-investigate.sh` | In manual (default) permission mode, deny: that mode is investigate-only. Also on UserPromptSubmit, where it injects the investigate posture |
| Bash | `~/.claude/hooks/token-filter.sh` | Rewrite a command through the method in `~/.agent/token-filter/mode` so less output reaches the model. Never denies; see "Token filter" |
| Agent\|Task\|Workflow | `~/.claude/hooks/spawn-watch.sh` | Ping the human when one session passes 40/80/160 spawns. Alert only: always exits 0, never denies |

## PostToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/board-observe.sh` | Record a sprint-board stage transition when the board is edited |
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/ai-comment-guard.sh` | Warn on AI-tell comments in what was just written |
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/context-budget-guard.sh` | Warn when an always-loaded file passes its budget: `MEMORY.md` 8 KB (or a line over 200 chars), global `CLAUDE.md` 20 KB, repo root `CLAUDE.md`/`AGENTS.md` 12 KB |

| Bash (PostToolUse and PostToolUseFailure) | `~/.claude/hooks/token-filter.sh` | When a rewritten command's output shows an rtk error, log it, feed the breaker, and tell the model the `RTK_DISABLED=1` re-run |

## Token filter

`token-filter.sh` cuts Bash tool output by rewriting commands through rtk (rtk-ai/rtk, the Apache-2.0 `rtk-oss` build, pinned and installed by `install_rtk` in `base_functions.sh`). `token-filter` is the CLI that switches it, checks it and measures it.

Methods, set with `token-filter use <method> --reason R` (each switch is a line in `~/.agent/token-filter/methods.jsonl`, which `claude-recall tool-output --by method` uses to bucket token use):

| Method | What gets rewritten |
|--------|---------------------|
| `off` (also: no mode file) | Nothing. The hook exits before reading its input |
| `rtk` | Everything `rtk rewrite` maps: git, gh, grep/rg, find, wc, jq, test runners, `cat` as `rtk read` |
| `rtk-vcs` | Only git, gh and test runners; reads and searches stay exact. The fallback when `rtk` mangles file text |

Safety contract:

- Fail-open: every path exits 0, and any error (rtk missing, rewrite timeout after 2s, bad JSON) leaves the command as written.
- It never sets `permissionDecision`, so a rewritten command is approved by the same rules as the original. A deny from `block-root-search.sh` or `block-pip.sh` still applies.
- A command carrying `RTK_DISABLED=1`, or matching a skip ERE, is left alone. Tracked defaults are in `~/.config/token-filter/skip`, with the reason for each; `token-filter skip add` and `verify --apply` write to `~/.agent/token-filter/skip`.
- Breaker: 5 failures (rtk missing, rewrite error or timeout, an rtk error in the output) within an hour switch the mode to `off`, log `by: breaker` in `methods.jsonl`, and page with `agent-notify`. Sessions keep working unfiltered.
- Logs: `~/.cache/token-filter/rewrites.jsonl` (every rewrite, keyed by tool_use_id), `failures.jsonl`, `verify.jsonl`.

Checks: `token-filter doctor` (pinned rtk, jq, hook registered, a live rewrite, the error hint and fail-open smoke-tested against a temp state) and `token-filter verify` (replays recent read-only Bash commands from the transcripts raw and rewritten, with a socket as stdin like the Bash tool, and flags a changed exit code, a hang, lost output, growth or an rtk error; `--apply` adds a skip for a failing single-command shape).

| Symptom | Cause | Fix |
|---------|-------|-----|
| Output of `ls -t \| head` is the wrong files | rtk 1.1.0 `ls` lists directories first and adds sizes | Tracked skip for `ls` (2026-11-04) |
| Nothing is ever rewritten, `rewrites.jsonl` empty | Mode file missing or `off`, or the breaker tripped | `token-filter status`; `token-filter use rtk` |
| Rewrites stopped mid-day, a page said "tripped to off" | 5 rtk failures in an hour | `token-filter status` lists them; skip the shape or `token-filter use rtk-vcs`, then back on |
| A one-off command needs exact output | rtk truncates long lines and caps grep results | Prefix the command with `RTK_DISABLED=1` |
| The hook was edited but behaves the old way | Stow points at the main checkout; a worktree edit is not live | Run the worktree copy by path, or land it |

## Token usage tracking

`agent-usage tokens snapshot` runs nightly as the first step of `day-log nightly` (agentctl `token-usage`, 03:40, in `~/.dotfiles-private/.config/agentctl/agents/`) and writes one JSON per finished local day to `~/.agent/token-usage/<date>.json`. It has no scanner of its own; it joins the two counted tools and the token-filter replay:

| Number | Owner |
|--------|-------|
| Responses, input, cache write, cache read, output; context per response; tool output and its carried cost by project, command head and method; `long_runs` | `claude-recall tool-output` |
| Cost (registry), sessions, merged PRs and cost per merged PR, start context (first-turn median), compactions, tokens by model, sessions by kind and account | `agent-usage burn` |
| The rtk replay, with a local skip added per failing shape (`--apply`) | `token-filter verify` |

- `carried_share` is carried tool output (about 4 chars a token) over all context read; `carried_x` is how many times its own size a tool result is re-read before a compaction drops it.
- `long_runs` lists the stretches between compactions that ran 150 or more responses (`claude-recall tool-output --long-turns N` to change it), top 10 by carried cost.
- `agent-usage tokens line` prints the one-line row that `day-log` and the `fleet-bench` scorecard show; `tokens json --date D` is the day's snapshot, which `day-log` copies into `.agents`.
- `agent-usage tokens check` compares context per response, carried share and the start-context median with the median of the 7 days before. It exits 1 past 25% either way, and 2 when the newest snapshot is more than 2 days old. The Sentinel watch `token-usage-drift` runs it every 6 hours. It only alerts; nothing caps or slows a session.

| Symptom | Cause | Fix |
|---------|-------|-----|
| The watch says the nightly run stopped | No snapshot in 2 days | `agentctl status token-usage`; run `agent-usage tokens snapshot` by hand for each missing day (`--date D`) |
| A row ends in "N source errors" | burn or token-filter failed; the rest of the day is still written | `jq .errors ~/.agent/token-usage/<date>.json` names the source |
| The row reads "unreadable" | `claude-recall tool-output` gave no totals, so the day has no numbers | Run the recall command from `.errors` by hand; re-run the snapshot for that day |
| The check says "baseline N days" | Fewer than 3 earlier snapshots | Wait, or backfill with `--date` |

## File layout

- `~/.claude/hooks/` is hard-linked to `~/.dotfiles/.claude/hooks/` (same inodes via stow).
- `~/.dotfiles/.config/shared-hooks/` holds hooks shared across runtimes (Claude Code + Codex).
- Project repos should NOT have their own `pre-stop-checks.sh` — the user-global one handles all project types. If a project needs custom CI, add a case to the global hook.

## Loop-guard contract

Every Stop hook that can exit non-zero MUST check `stop_hook_active` from stdin and exit 0 on the second call. Without this, the agent loops forever when it can't fix the failure (e.g., plan mode).
