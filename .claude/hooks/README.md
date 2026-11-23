# Claude Code Hook Topology

## Stop hooks (user-global, in ~/.claude/settings.json)

One Stop entry, one entrypoint:

| File | Job |
|------|-----|
| `~/.claude/hooks/pre-stop-checks.sh` | Coordinator: runs parallel `stop-checks.d/`, then `stop-post.d/`. Single source of all Stop-time behavior. |

The coordinator runs two phases:

```
phase 1  stop-checks.d/ parallel, exit-code aggregated, may BLOCK (exit 2); skipped when no files changed since SessionStart
phase 2  stop-post.d/  sequential, stdout/stderr passed through, may BLOCK (JSON or exit 2); runs ALWAYS
```

Loop guard: coordinator and any `*.d/` script reading stdin should check `stop_hook_active` and exit 0 on the second call. The exception is a session with `/wind-down` armed: its loop-guarded Stop re-runs the checks for a fresh verdict and then `95-wind-down.sh` alone, which needs no guard because it never blocks. A post script that blocks a Stop holds the teardown on that Stop only. Coordinator passes the JSON payload to the `stop-post.d/` children via stdin so they can self-loop-guard. The `stop-checks.d/` children run with no stdin; they get the payload's session id as `STOP_SESSION_ID`.

Anything that must fire on every Stop, including a pure Q&A turn with a clean tree, goes in `stop-post.d/`: it runs after the checks or after the clean-tree early exit.

### `stop-checks.d/` — content checks (parallel)

Each `*.sh` is one independent check. The coordinator fans them out in parallel and aggregates by exit code:

| Exit code | Meaning | Coordinator behavior |
|-----------|---------|----------------------|
| `0` | pass (or check not applicable) | silent |
| `1` | warn / advisory | logged; coordinator still passes |
| `2` | block | coordinator exits 2; Claude is gated |
| other | block (defensive) | same as `2` |

SessionStart snapshots tracked and untracked file state with `stop-session-changes.py`, preserving the snapshot on resume and compaction. Stop exports the paths changed since that snapshot as `STOP_CHANGED_FILES`, less any whose content now matches origin's default branch (`origin/HEAD`, else `origin/main` or `origin/master`), and any gone path that branch lacks but the fork point of the session's starting HEAD held, since a merge or fast-forward brought those in (a snapshot from before it recorded HEAD counts every deletion); the checks use that list instead of branch or pre-existing worktree dirt. A session without a snapshot skips content checks. Payloads without a session id retain the legacy worktree check.

A timed-out check with no reported failures is logged and recorded as SKIPPED, does not block, and is never cached as a passing run. TAP failures printed before timeout still block.

Project-type detection lives **inside each check** (e.g. `[ -f package.json ] || exit 0`), so the coordinator stays project-agnostic. To add a check, drop `<NN>-<name>.sh` into `stop-checks.d/` and `chmod +x`. Checks run in parallel — order is informational only.

Current checks: `10-git-workflow.sh` (unpushed commits, which only warn while a background run of this session is live, read as a process holding its `tasks/<id>.output` open; a queue item's session pushes them instead and records `branch:` on its item, and is blocked when the item names it in `lost:`). Nothing runs typecheck, lint, cargo, python, go or the bats fast tier at Stop, or on `git push` or `gh pr create`: the CI fast job on hosted runners is the gate (a session reads its bats red at CI, minutes later), the way Unity's gate runs only on the pool (`unity-core-playground` `docs/operations/ci.md` rule 2). The Stop check covers the dirty tree only, so a red in work committed and pushed in one turn is caught and fixed in CI.

The coordinator writes `status=PASS|FAIL|SKIPPED` and `note=...` to `$XDG_CACHE_HOME/claude-stop-hook/ci-result-<session_id>.txt` (`ci-result-<proj>-<date>.txt` only when the payload has no session id) and exports the path as `CI_RESULT_FILE` to the post scripts. `95-wind-down.sh` reads it from there and never builds the name itself. Files older than a week are pruned.

### `stop-post.d/` — runs after content checks (sequential, can block)

Each `*.sh` runs sequentially with stdout/stderr piped straight to the coordinator's stdout/stderr. This means a post-check *could* block by printing a Claude Code Stop-hook JSON object on stdout (`{"decision":"block","reason":"..."}`), or by exiting 2 with a stderr message - same protocol as a top-level Stop hook. Most post-checks never block; `88-ask-filed.sh` and `89-coord-watch.sh` block a turn once, with the instruction to follow.

Current post-checks, in order:
- `80-session-register.sh`: records the session in the session registry.
- `85-sync-plans.sh`: links the plans this session wrote into `~/.agent/plans/<proj>/`, each a relative link into `~/.agent/plans/_live/`, the one store (`~/.claude/plans` links to it, `claude-acct plans-store`).
- `86-empty-wakes.sh`: when an attended session that is not a `coordinator` has woken `EMPTY_WAKE_MAX` (4) times in a row on a Monitor expiry with no events since its last real prompt, labels it `spinning` and blocks each such wake once with the step (stop the watch, let the ask or a background command that exits carry the wait); from twice that it pages once per run (`~/.local/state/empty-wakes/<id>.paged`). Removes the label after a real prompt.
- `87-regen-anchor.sh`: regenerates the project anchor's auto block.
- `88-ask-filed.sh`: when an attended session outside plan and manual mode ends its turn asking the human something, made no AskUserQuestion or ExitPlanMode call that turn, and owns no pending ask, blocks once with the instruction to file it with `agent-ask post`.
- `89-coord-watch.sh`: when an attended session carries the `coordinator` label (coordinate skill) and no live `coord-watch` of its own is recorded (`~/.local/state/coord-watch/session-<id>.pid`), blocks once with the step to arm it; when the recorded plan has no open ledger line, the step is coordinate step 6 instead, never a re-arm.
- `90-session-spend.sh`: when an attended session that is not a queue session passes `CLAUDE_SESSION_ALERT_USD` ($60) of OTel cost in Prometheus, pages once at 1x, 2x, 4x and so on. Alert only: always exits 0 and prints nothing.
- `94-self-close.sh`: when a dispatched session (`$AGENT_QUEUE_ITEM`, its item naming this session) in an attended session ends a turn with its item done and `fleet-sessions close --self` reading now, blocks once per session (a marker in `~/.local/state/self-close/`) with the step to run `/wind-down auto` in that turn, while its context is still cached. Any other verdict passes, and the shepherd's typed close stays the backstop.
- `95-wind-down.sh`: fires this session's armed spin-down request (`~/.agent/spin-down/<session_id>.request`, written by `wind-down.sh arm`), deferring while `$CI_RESULT_FILE` says FAIL. A fired request stays as `.fired`, which `fleet-dispatch restore` reads to leave that conversation closed, and the next prompt in that session clears it and tells the model "wind-down is not armed", since a resumed conversation still reads its old "wind-down armed" line. It also deletes any request or `.fired` older than a day.

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
| Bash, Read | `~/.claude/hooks/block-poll.py` | Deny a foreground `until`/`while`/`for` loop that sleeps (a wait), and a foreground Bash or Read tool read of a background task's `tasks/<id>.output` while a process still holds it open (the run is live): it points at `run_in_background`, Monitor, the completion notice and the shared CI-run waiter `gh-run-wait`. A background loop, a script file, quoted text and a read after the run exits are allowed |
| Bash | `~/.claude/hooks/hand_methods.py` | Deny a hand-typed form a skill's `metadata.replaces` names with `mode: deny` (`gh run watch` and `gh run rerun` / `gh api .../rerun` are gh-workflows rows, the rerun one with an `unless` for a command that carries `# infra: <fault>`, and `gh run cancel` / `gh api .../runs/<id>/cancel` with one for `# own: <pr>` or `# stuck: <step>`; a `-f` pattern kill, a generic interpreter kill and a recursive search from `/` or `/mnt` are fleet-pace rows, with `tests/integ/fleet_pace_replaces.bats`), naming the skill and what to run instead. The rows live only in the skills' frontmatter, cached per skills root under `~/.cache/claude-hooks/`; it reuses block-poll's parse, so quoted text and heredoc bodies are not code. `--list` prints the rows |
| Bash | `~/.claude/hooks/walker-guards.py` | Runs the five guards on forge-guard's walker (the next five rows) in one Python process: reads the payload once, calls each one's `decide(data)`, and names every guard that refuses in one deny. A guard that raises is skipped and the rest still run. `tests/integ/walker_guards.bats` |
| via walker-guards | `~/.claude/hooks/forge-guard.py` | In a checkout that commits `.forgejo/workflows/mirror-to-github.yaml` (Forgejo canonical, GitHub a passive mirror: home-config), deny `gh pr create`, `gh pr merge` and a `git push` to a github.com remote, pointing at the Forgejo remote, `forgejo-ops` to open the PR and `agent-land` to land it. It follows `cd`/`pushd` (subshell-scoped), `git -C`, `bash -c`/`eval`, and `gh -R`, GH_REPO or a PR URL (via project-map `paths`). Why: home-config GitHub PR 62 was opened and merged from a dotfiles session on 2026-11-06, and the mirror's reject-pull-requests workflow closes a PR too late. Anywhere else it denies `gh pr merge` and names `agent-land <N> --repo <r>`, the one writer of a queue item's `pr:`; why: 41 of the 62 merged PRs no item named (11-07 to 11-09, `ledger_coverage`) were merged that way in sessions that had an item. On any forge it denies a merge through the PR API (`curl -X POST .../pulls/N/merge`, `gh api -X PUT`) and names `agent-land`, which lands a Forgejo PR through that API; why: 12 of the 62 were home-config and bnb-game-servers PRs merged by a raw Forgejo call (ar-1213). Fail-open; `tests/integ/forge_guard.bats` |
| via walker-guards | `~/.claude/hooks/checkout-guard.py` | In a checkout stow deploys (`~/.dotfiles`, `~/.dotfiles-private`), deny `git checkout`/`git switch` to anything but the default branch and `gh pr checkout`, naming `git show` and a worktree instead. Reuses forge-guard's walker. Fail-open. Tests: `tests/integ/checkout_guard.bats` |
| via walker-guards | `~/.claude/hooks/release-guard.py` | No agent cuts a release: deny `git tag` of a release tag (`v<n>.<n>`, `<name>-v<n>.<n>`), a `git push` carrying or deleting one or pushing `--tags`, `--follow-tags` or `--mirror`, `gh release create` of a tag not on origin, `gh workflow run cut.yml`, the cut scripts (`scripts/release/{ship,release,publish}.sh`, or a repo's `scripts/release.sh`, `scripts/publish.sh`), `gh api`/curl writes to `rulesets`, `environments` or `keys` and `gh repo deploy-key add/delete`, and the untested override (`RELEASE_UNTESTED=`, `untested-reason`). A release workflow (`release.yml`, `phone-release.yml`, `ios-release.yml`, `steam.yml`) runs only as a re-send of a tag `git ls-remote` finds on origin; `gh run rerun` passes. Reuses forge-guard's walker; Codex runs it from `.config/codex/hooks.json`. Why: the human, 2026-11-19 (ucp-2709): the system cuts through `cut.yml` when the sprint says so, an agent only fixes and re-sends. Fail-open, except a tag origin does not answer for. Tests: `tests/integ/release_guard.bats` |
| via walker-guards | `~/.claude/hooks/scratch-rm-guard.py` | Deny an `rm -r` that would remove, or reach into, a `~/.cache/<tool>/<id>/` dir whose `<id>` is a live session other than the caller's (a process of this user carries it in `CLAUDE_CODE_SESSION_ID` or `CODEX_THREAD_ID`), naming the session and its pid. The caller's own scratch and a dead session's dir pass. Also deny an `rm -r` of `/` or what `rm -rf /*` expands to (each top-level entry and the dir a top-level symlink reaches): Claude's built-in rm check covers those, Codex has none, and settings.json cannot deny the literal because Claude reads its `*` as a wildcard over every absolute path. Reuses forge-guard's walker. Why: on 2026-11-10 an rm -rf of `~/.cache/hub-spend-history` killed another session's backfill. Fail-open; `tests/integ/scratch_rm_guard.bats` |
| via walker-guards | `~/.claude/hooks/gh-login-guard.py` | Deny a session's change to this host's gh login: `gh auth login`, `logout`, `refresh` or `switch` (unless the config dir gh would use for that command resolves elsewhere, a throwaway home), and an rm, mv, copy, `dd of=`, `sed -i`, find `-delete`/`-exec`, tee or redirect that removes or writes the gh config dir. Its reason says signing gh back in is the human's and names the workarounds not to take; the session preflight says the same when gh is signed out. Why: a test run deleted `~/.config/gh/hosts.yml` and signed the fleet out (2026-11-17, ar-2876). Codex runs it too. Fail-open; `tests/integ/gh_login_guard.bats`, `tests/integ/preflight_gh_login.bats` |
| Bash | `~/.claude/hooks/python-write-guard.py` | Deny a python heredoc or `-c` write that Edit or Write makes one-for-one, of a file an Edit/Write check covers (a workflow file, hosted-runner-guard; a CLAUDE.md, AGENTS.md, SKILL.md, or `.md` in memory or lessons, context-budget-guard; a path `settings.json` permissions.deny denies to Edit, such as `.env`, ssh keys and `~/.config/gh`), so that check sees it: a str.replace patch of a named file (the code calls only open, path and plain str methods) or a literal string written to one. Any other file, computed content (regex, json, joins), files found in a loop, bytes, appends and scratch (/tmp, ~/.cache) pass. In manual mode it denies any python write outside scratch. Why: `settings.json` allows all of Bash, and usage-cleanup pass 6 counted 11.2k of 15k python3 calls as `open().read().replace()` patches that skipped every Edit/Write guard (ar-2018); held to guarded files since 94% of 7 days' denies were of other files, each a turn spent for no guard (ar-2780). Claude only: Codex has no Edit tool. Fail-open; `tests/unit/python_write_guard.bats` |
| Read, Bash | `~/.claude/hooks/large-read-guard.py` | Deny a Read with no `limit`, or a `cat` whose output reaches the context, of a text file over 2,000 lines, naming `rg -n -C 8` and offset/limit; a Read with a limit passes. It replaced an additionalContext hint that fired 362 times in 7 days and changed nothing. Fail-open; `tests/unit/large_read_guard.bats` |
| Edit\|Write\|MultiEdit\|NotebookEdit\|EnterPlanMode | `~/.claude/hooks/manual-mode-investigate.sh` | In manual (default) permission mode, deny: that mode is investigate-only. The deny reason carries the posture; there is no prompt-time inject |
| Edit\|Write\|MultiEdit | `~/.claude/hooks/hosted-runner-guard.py` | Deny writing a GitHub-hosted runner label (`ubuntu-latest`, `ubuntu-24.04`, `macos-*`, `windows-*`) into a `.github/workflows/` file of a repo whose origin owner is in project-map.json `github_runners.self_hosted_only`, naming `vars.LINUX_RUNNER_LIGHT`; `github_runners.allow` lists the exceptions. Work orgs are not listed, and a public repo passes (hosted is free there; a self-hosted runner would run fork PR code on the LAN). `tests/unit/hosted_runner_guard.bats` |
| ExitPlanMode | `~/.claude/hooks/plan-standard.sh` | Deny a plan with no valid `epic:` line (`planning.md`, `Epic:`), naming each gap, a plan with more than one open phase that says it runs in one session (planning.md, `Chain:`), and a phase marker `agent-queue add --plan --check` refuses (an `(after N)` with no `needs <result>`, a shared-file reason, one that does not parse). The same hook on UserPromptSubmit injects those three rules in plan mode. It checks nothing else: the Sections table is the written standard only. Fails open when the doc is missing |

A deny (PreToolUse) or block (Stop) reason starts with `<hook-name>: `. session-outcomes counts each denial under that name in the outcome row's `guards`, which is how a guard's effect is counted; a reason with no name lead is invisible to it (`tests/unit/session_outcomes.bats` "guards").

## PostToolUse hooks (user-global)

| Matcher | File | Job |
|---------|------|-----|
| ExitPlanMode | `~/.claude/hooks/plan-approved.sh` | Record the approved plan in `~/.agent/plans/approved.jsonl`, so `fleet-dispatch reap` can queue its open phases once its session is gone, and propose its `epic: new` line: filed in a hand session with the line rewritten to the id, or sent to the outbox |
| (every tool) | `~/.claude/hooks/long-session-handoff.sh` | In a dispatched session's main thread on a pilot repo (`AGENT_HANDOFF_REPOS`, unity-core-playground), once its transcript passes `AGENT_HANDOFF_TURNS` (150) responses or a compaction, tell it once to hand its item to a fresh session through `agent-queue handoff` (a pushed branch, a `## Handoff` note, then `/wind-down auto`); the next brief reads the note (`handoff_line`). A hand session is never told. `tests/unit/long_session_handoff.bats`. |
| Edit\|Write\|MultiEdit\|NotebookEdit | `~/.claude/hooks/context-budget-guard.sh` | Warn when the global `CLAUDE.md` passes 20 KB or a repo root `CLAUDE.md`/`AGENTS.md` 12 KB, and when a memory, lessons or SKILL.md edit restates another home's instruction |

## Token usage tracking

`agent-usage tokens snapshot` runs nightly as the first step of `day-log nightly` (the `token-usage` step of the agentctl `nightly-measure` runner, its last step, after the 02:30 start, in `~/.dotfiles-private/.config/agentctl/agents/`) and writes one JSON per finished local day to `~/.agent/token-usage/<date>.json`. It has no scanner of its own; it joins the counted tools below:

| Number | Owner |
|--------|-------|
| Responses, input, cache write, cache read, output; context per response; tool output and its carried cost by project, tool and command head; `long_runs` | `claude-recall tool-output` |
| Tool latency (slowest tools by total time), tool errors by class, gateway calls, errors by class, cost and tokens per upstream model: `langfuse`, null when Langfuse could not answer | `agent-usage langfuse` |
| Cost (billed sessions; `fleet_cost` in the snapshot is every session, billed or priced at fitted rates), sessions, merged PRs and cost per merged PR (fleet cost), start context (first-turn median), compactions, tokens by model, sessions by kind and account | `agent-usage burn` |

- `carried_share` is carried tool output (about 4 chars a token) over all context read; `carried_x` is how many times its own size a tool result is re-read before a compaction drops it.
- `by_tool[].allocated_cost_usd` is an allocation, never a metered figure: each registry session's cost of the day is split over its tools by their share of its carried output (`claude-recall tool-output --by session,tool`, a subagent's output counted for its parent). A session that carried no tool output allocates nothing, and its cost is `by_tool_unallocated_usd`, so the two sum to `totals.cost_usd`.
- `long_runs` lists the stretches between compactions that ran 150 or more responses (`claude-recall tool-output --long-turns N` to change it), top 10 by carried cost.
- `agent-usage tokens line` prints the one-line row that `day-log` and the `fleet-bench` scorecard show; `tokens json --date D` is the day's snapshot, which `day-log` copies into `.agents`.
- `agent-usage tokens check` compares context per response, carried share and the start-context median with the median of the 7 days before. It exits 1 on a rise past 25% (worse) or a drop past 50% (measurement suspect; a drop inside that is an improvement and stays quiet), and 2 when the newest snapshot is more than 2 days old. The Sentinel watch `token-usage-drift` runs it every 6 hours. It only alerts; nothing caps or slows a session.
- The `langfuse` section is the gateway's figures alone (LiteLLM calls, not Claude sessions): session cost stays `agent-usage burn`, so the two are never summed. The Costs tab shows it as "What Langfuse sees" (hub `l`), from the newest snapshot.
- `agent-usage tokens check --langfuse` is the read-health watch (`langfuse-read`): exit 1 when the newest two snapshots both carry a null `langfuse` section, naming the reader's reason from `.errors`. One null night is quiet; a snapshot with no `langfuse` key at all (written before the reader) is not a null night.
- `agent-usage tokens check --gateway-errors` is the `gateway-errors` watch: exit 1 when the newest snapshot's `langfuse.gateway.by_error` has a `BadRequestError` (a caller sending a request the model API refuses). Auth probes (`HTTPException`, `KeyNotFoundError`), `BudgetExceededError` and `ProxyRateLimitError` are quiet; `TOKENS_GATEWAY_TRIP` (comma list) and `TOKENS_GATEWAY_MIN` (at least 1) tune it. It reads one night, so a trip repeats on each 6h run until the next snapshot, and Sentinel notifies on the edge only.

| Symptom | Cause | Fix |
|---------|-------|-----|
| The `langfuse-read` watch trips | The reader failed two nights running: no rbw key, Langfuse down or a changed API | `jq '.errors' ~/.agent/token-usage/<date>.json` for the reason; run `agent-usage langfuse --since T --until T` by hand; re-run `agent-usage tokens snapshot --date D` once it reads |
| The `gateway-errors` watch trips | A caller sent the gateway a request the model API refused (BadRequestError, often a param or model the route does not support) | `jq '.langfuse.gateway.by_error' ~/.agent/token-usage/<date>.json`; find the caller in Langfuse by `attributes.error.type`; the fix is in the caller or the route |
| The watch says the nightly run stopped | No snapshot in 2 days | `agentctl status nightly-measure` (its token-usage step); run `agent-usage tokens snapshot` by hand for each missing day (`--date D`) |
| A row ends in "N source errors" | burn or one recall query failed; the rest of the day is still written | `jq .errors ~/.agent/token-usage/<date>.json` names the source |
| The row reads "unreadable" | `claude-recall tool-output` gave no totals, so the day has no numbers | Run the recall command from `.errors` by hand; re-run the snapshot for that day |
| The check says "baseline N days" | Fewer than 3 earlier snapshots | Wait, or backfill with `--date` |

## File layout

- `~/.claude/hooks/` is a stow symlink to `~/.dotfiles/.claude/hooks/`.
- `~/.dotfiles/.config/shared-hooks/` holds hooks shared across runtimes (Claude Code + Codex).
- Project repos should NOT have their own `pre-stop-checks.sh` — the user-global one handles all project types. If a project needs custom CI, add a case to the global hook.

## Loop-guard contract

Every Stop hook that can exit non-zero MUST check `stop_hook_active` from stdin and exit 0 on the second call. Without this, the agent loops forever when it can't fix the failure (e.g., plan mode).
