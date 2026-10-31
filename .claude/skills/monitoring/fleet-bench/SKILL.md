---
name: fleet-bench
description: >-
  Benchmark the agent fleet from counted facts: where every live session is in its plan, when it should finish, and afterwards how far off that prediction was. Verbs: findings | throughput | report | eta | headline | scorecard | sample | review | asks | ledger | kpi | retro. Use when the user asks "how accurate are the ETAs", "when will agent-N be done", "benchmark the sessions", "how fast is the fleet moving", "show me the scorecard", "how often does CI go red before merge", "review a sample of merged PRs", "which asks are blocking", "what is waiting on me", or when the shepherd writes a "where are we" summary and needs an ETA per session. Model-free except `review`, which runs a non-Claude model (deepseek-v4-pro on the Lazer allowance) through the runner's route. Not for load or holds (fleet-overseer) and not for what one session did after it ended (session-outcomes).
metadata:
  category: monitoring
  tags: [agents, fleet, benchmark, estimates, observability]
  reviewed: "2026-10-30"
---

# fleet-bench

On 2026-10-27 the shepherd told the human when each session would finish ("about 9:00 PM", "tomorrow around midday") by assuming one phase per hour. Nothing kept those numbers and nothing checked them. The first one scored, an hour later, took up to 2.6x as long as predicted. This skill is the record and the check. It is a component of its own, like `fleet-dispatch`: the shepherd only reads it.

Every number here is counted from samples. None is a model's grade, because model-graded evals on this fleet read 10/10 almost every time and rank nothing.

## Where to look

- `~/.notes/lab/projects/current/agent-runtime/bench/latest.md`: the daily scorecard, one row per session over the last 24h (phase now, phases ticked, hours working, hours waiting on you, hours stalled, nudges, peak context, then PRs merged, CI reds, reverts and cost), and under it the review sample. One dated file per day sits beside it. It syncs with notes, so it reads on the phone.
- The morning briefing (`agentctl-briefing`, 06:45) writes the scorecard, puts the headline and its path in `briefing.md`, and carries the pending-asks line in its one page.
- `~/.notes/lab/projects/current/agent-runtime/bench/asks.md`: every pending ask, the ones blocking a live session first, rewritten by the briefing at 06:45 and 18:45. The 18:45 run pages it on its own (`-t asks`), naming the top three and what each session recommends.
- `fleet-bench report`: every live session (phase done/total, bucket, ETA, what the ETA is based on), then how accurate past ETAs were, then the last agentctl outcome of `fleet-bench`, `fleet-review` and `briefing`.
- `fleet-bench eta`: one line per live session, or `--json` for scripts. The shepherd's "where are we" summary takes its ETAs from here.
- Prefix + Ctrl-g (`fleet.sh`) has a `bench` section under the asks: the headline, then one ETA row per live session. Its runners section lists `fleet-bench` and `briefing` with every other agentctl unit, red when the last outcome is STALLED or the run failed.
- `agentctl status fleet-bench` and `agentctl logs fleet-bench -f` for one run's detail.

## Verbs

- `sample`: one pass. It reads `fleet-sessions --json`, appends one line per live session to `progress.jsonl`, writes an estimate for any session whose phase count has no estimate yet, and scores every estimate whose session has since finished. The agentctl runner `fleet-bench` runs it every 10 minutes: `fleet-sessions` has no event to wait on, so this is a steady poll, and one run costs about 14 s, mostly `gh`.
- `eta [--json]`: the newest estimate per live session from the newest sample, calibrated when its basis has enough scores (see "How the numbers are made"). A finished session has none. `--json` gives `eta`/`eta_epoch` (the ETA shown, calibrated when it was), `raw_eta_epoch`, `factor` and `basis`.
- `report`: as above. Read-only.
- `accuracy --json`: one object per basis kind from `scores.jsonl`: `basis`, `n` (scored), `n_ratio` (scored with a ratio), `median_ratio`, `median_error_min`, `median_abs_error_min`, and `factor`, the calibration a new estimate of that kind gets now (null below the minimum). The same function makes the factor and the report's per-basis lines, so all three always agree. The watch board's ETA trust line reads it.
- `headline`: the last `BENCH_WINDOW_H` (24) hours in one line: sessions, phases ticked, hours waiting on you, hours stalled, ETAs scored and their median raw ratio, and the calibrated ones' median ratio when any were scored.
- `scorecard`: writes `<date>.md` and `latest.md` in `BENCH_SCORECARD_DIR` and prints the path. Sections: KPIs; Bottlenecks (hours lost per queue, on runs not passed, waiting on you and stalled, biggest first, then the branches behind the failed runs); Where the time went (per project and plan, with 24h spend and merges); Sessions; Agent depth (test runs, CI polls, tool errors and tokens past the last edit, from session-outcomes' `activity`); Session time (hours per project over `BENCH_TIME_DAYS` by what was running: work, gate, test, other jobs, you, parked, from session-outcomes' `time_use`); ETA accuracy; Review sample; Consolidation ledger. A source that cannot be read shows `?` or says so; it is never left out.
- `review [--pick]`: for every PR that session-outcomes lists as merged in the window and `pr-ci.jsonl` has not counted, one `gh pr view` and one `gh run list --branch` give its size and its CI runs from its first commit to merge. Then, when the runner's conf names a `ROUTE`, the reviewer reads up to `BENCH_REVIEW_MAX` (5) of them: the largest per session at most `BENCH_REVIEW_MAX_LINES` (2000) diff lines, largest first. `--pick` prints that list and calls nothing. The agentctl runner `fleet-review` runs it at 02:45, after session-outcomes (02:30) and before the 06:45 scorecard.

- `asks [--write|--page]`: every pending ask from `agent-ask list --all --pending`, joined to the newest sample of the session its `session` field names (a session id or a tmux session name). It prints the digest; `--write` also writes `asks.md` in `BENCH_SCORECARD_DIR` and prints the one-line summary (counts and the top three) with no page and no verdict, for the morning briefing to carry; `--page` writes `asks.md` and sends that line as one `agent-notify -p normal -t asks` page, which the briefing's 18:45 run does.

- `ledger [--json|--check]`: the consolidation ledger. It counts runner confs (`runners`, `runners_on` without `ENABLED=no`), generated `agentctl-*.timer` files, files with a direct headless `claude -p|--print` outside agentctl-run (`launches_direct`, gitignored build output skipped), distinct `last-outcome` verdicts, pending asks and those older than `ASK_STALE_DAYS` (14), and open agent-board rows. `--check` prints each of `runners`, `timers` and `launches_direct` that is over `~/.config/agentctl/ledger-baseline` and exits 1 (2 with no baseline). To add a runner, timer or launch, retire one or raise the baseline in the same PR with a why. The scorecard carries the counts and the check under "Consolidation ledger". `--launches DIR...` prints the scan's matches; `runner_contract.bats` uses it.

- `kpi [--json]`: the KPI table over the last 7 and 28 days (`| KPI | 7d | 28d | threshold | status |`), or one JSON object keyed by KPI; the scorecard carries it under "KPIs", right after the headline.

- `retro`: for each KPI whose 7d value is past its threshold, keeps exactly one open row `kpi: <key> past threshold: 7d <v> (28d <v>, max <t>)` on the agent-runtime agent board (`now <v> (max <t>)` for a count taken now): it adds the row (`#high` when more than 2x past, else `#low`) or refreshes its numbers with `ptask edit`, and touches no other row. WORKED when it wrote, NOOP otherwise, and NOOP with no notes call when there is no thresholds file. The briefing runs it on Mondays.

- `findings [--open|--json|--run]`: conclusions that want a decision, from rules over counted facts on every machine. It prints what is open, worst class first; `--json` gives the rows; `--run` evaluates and appends, and every `sample` does. See "Findings".

- `throughput [--from T] [--to T]`: runs/h, share not passed, editor-hours and those spent on runs not passed, merges/h per project, each pool's queue, and load per core on every host over 0.5x. Default window is the last 2h; T is an epoch or anything `date -d` reads. Any slot, hold or pace change states this number before and after. Read-only apart from a `git fetch` of each project's default branch.

### Findings

`fleet-assess` decides for this workstation alone. Findings read the pool and the other hosts too, and they are in shadow: nothing pages on them yet (plan `can-we-update-shepherd-composed-hopcroft`).

| Rule | Fires when | Reads | Class |
|---|---|---|---|
| `starved <host>` | `finding_queued_min` (5) local runs queued on 2 samples and the CPU over `finding_local_idle_min` (0.3) idle | `cc:host_local_queued`, `cc:host_cpu_busy_ratio` | shepherd, human after `finding_human_after_min` (60) |
| `starved pool:<pool>` | oldest job waited `finding_pool_wait_s` (3600) with jobs still waiting. Busy share under `finding_pool_idle_share` (0.75) concludes admission or labels, otherwise demand over capacity | `cc:pool_*` | shepherd, human after that |
| `throughput-drop <project>` | merges/h over 2h under `finding_merge_ratio` (0.5) of the 24h rate, with a 24h rate of at least `finding_merge_floor_h` (2)/h, while live sessions hold at `finding_demand_ratio` (0.7) of their 24h average | `git log --first-parent`, `progress.jsonl` | human |
| `host-overload <host>` | load per core at `finding_host_load_per_core` (2) on 3 samples | `cc:host_load1`, `cc:host_cores` | report, human after that |
| `blind <source>` | Prometheus unreadable, a series missing, a project's merges unreadable (no mapped repo, or the fetch failed), the rules themselves failing, or nothing evaluated within `finding_clear_min` | every source | report |

- **Demand is sessions, not runs.** Local runs fall by design once gates move to the pool, so runs/h would read that as demand gone.
- **Episode.** The time a rule first fired for a scope. It outlives a gap up to `finding_clear_min` (60), so one outage is one episode, and a recurrence after that is a new one. `fact` is `<rule> <scope> @<episode>`, the key a ledger pages once on. There are no close rows: a finding is open while its newest row is inside the clear window.
- **Thresholds** are starting points set from the 10-29 replay. Defaults are in the code; a `finding_*=` line in `KPI_THRESHOLDS` overrides one.
- **Replay.** `tests/fixtures/bench-replay-1029/` is that day, read through `BENCH_NOW`, `BENCH_PROM_TSV`, `BENCH_MERGES_TSV` and `BENCH_RUNS_TSV`. The rules fire at 09:30 (pool), 13:00 (local slots) and 14:20 (merges); the human found it at 19:59.

### KPIs

Windows count human sessions by `updated_epoch` in session-outcomes; a line with `runner: true` or project `_runner` is headless and left out (older lines have no `runner` field and count as human). A ratio over zero is `-` (null in `--json`).

| Key | Value |
|---|---|
| `sessions` | human sessions seen in the window |
| `prs_per_session` | sum `prs_merged` / sessions |
| `revert_rate` | sum `reverted_7d` / sum `prs_merged` |
| `interrupts_per_session` | sum `corrections.interrupts` / sessions |
| `cost_per_pr` | sum `cost_usd` / sum `prs_merged` |
| `ci_red_per_pr` | sum `ci_red` / rows in `pr-ci.jsonl` by `merged_epoch`, headless sessions' PRs left out |
| `runners_bad` (now) | switched-on runner confs whose `last-outcome` is FAILED or STALLED (also in `ledger`) |
| `asks_stale` (now) | the ledger's `asks_stale` |
| `board_open` (now) | the ledger's `board_open` |

Thresholds are data in `KPI_THRESHOLDS` (default `~/.config/agentctl/kpi-thresholds`, private overlay), one `<kpi>_max=` or `<kpi>_min=` line each. A KPI with no line has status `-`; a missing file leaves every status `-` and makes `retro` a NOOP.

## How the numbers are made

State is in `~/.agent/bench/` (override with `FLEET_BENCH_DIR`).

| File | One line per | Fields that matter |
|---|---|---|
| `progress.jsonl` | session per sample | `epoch`, `session_id`, `target`, `project`, `bucket`, `phases_done`, `phases_total`, `finished`, `idle_min`, `context_tokens`, `nudged` |
| `estimates.jsonl` | session per phase count | `made_epoch`, `eta_epoch` (raw), `per_phase_min`, `basis`; when calibrated also `factor`, `factor_n`, `cal_eta_epoch` |
| `scores.jsonl` | estimate whose session finished | `error_min`, `ratio` (both against the raw ETA), `horizon_min`, `done_bound`; when calibrated also `factor`, `cal_error_min`, `cal_ratio` |
| `pr-ci.jsonl` | merged PR | `repo`, `number`, `session_id`, `merged_epoch`, `additions`, `deletions`, `ci_runs`, `ci_red` |
| `findings.jsonl` | firing finding per sample | `epoch`, `rule`, `scope`, `episode`, `decision_class`, `evidence`, `conclusion`, `cost`, `fact` |
| `reviews.jsonl` | reviewed PR | `status` (ok or failed), `block`, `flag`, `nit`, `findings[]` (`severity`, `where`, `summary`), `route`, `exit` |

- **Phase time.** Each plan file is its own timeline, so a session that starts a new plan does not count the switch as a phase. A phase is measured only when the samples saw both its start and its end, so a session's first phase on the record is never measured (it may have started hours earlier). When one sample sees two phases tick at once, the gap is split evenly between them. The time includes waiting on the human.
- **ETA** = now + phases left x per-phase minutes. Per-phase is the median measured phase time of that session (`basis: session-median(n)`), else of every session in its project (`project-median(n)`), else `BENCH_DEFAULT_PHASE_MIN`, 60 (`default`). A new estimate is written only when the phase count changes, so one estimate stands for each step of a plan and is scored as it was made.
- **Calibration.** The raw ETA runs long or short by a measured amount per basis (on 2026-10-28 project-median ETAs took 0.3x as long as predicted), so each new estimate also gets a factor: the median raw `ratio` over every score of the same basis kind (`session-median`, `project-median`, `default`, `shepherd-guess`), counting only scores that have a ratio. It applies only once that kind has `BENCH_CAL_MIN_N` (5) of them, clamped to `BENCH_CAL_MIN` (0.25) and `BENCH_CAL_MAX` (4), and rounded to 0.01. Then `cal_eta_epoch` = made + (raw ETA - made) x factor, and every view (`eta`, `eta --json`, `report`, the bench section of Prefix + Ctrl-g, the shepherd's summary) shows it, with the basis reading for example `project-median(13) x0.3 (n=23)`. Below the minimum the raw ETA is shown and the basis has no factor. The factor is fixed when the estimate is made, so a published ETA does not move as later scores land; an estimate made before calibration existed shows raw until its session's next phase tick. The raw ETA stays in `eta_epoch` and is what `ratio` is scored against, so the factor is always made from raw ratios: scoring the calibrated ETA instead would pull the ratio to 1 and the factor would undo itself.
- **Finish** is the first sample that reads `finished` (fleet-sessions' DONE work conditions). If that was the session's first sample at all, the real finish was earlier, and the score says `done_bound: upper`.
- **Score.** `error_min` = finish - ETA (positive means it ran long). `ratio` = actual duration / predicted duration (2 means it took twice as long). `horizon_min` = how far ahead the ETA looked. A calibrated estimate is also scored against its calibrated ETA (`cal_error_min`, `cal_ratio`), so the report shows whether calibration helps. The report gives medians by basis, by basis calibrated, and by horizon (under 2h, 2-8h, over 8h).
- **Scorecard hours.** Each sample owns the time until the next sample of that session, in that sample's bucket: WORKING is working, NEEDS is waiting on you, STALLED is stalled. A gap longer than `BENCH_GAP_CAP_MIN` (20, two cadences) counts as 20 minutes, because a longer gap means the sampler itself was down. Nudges count each time the shepherd's `nudged` flag turns on. PRs merged, reverts and cost are the newest session-outcomes line for that `session_id`, `-` when it has not been observed yet.
- **CI reds.** Runs on the PR's branch from its first commit (or its opening, if earlier) to its merge. Red is `failure`, `timed_out` or `startup_failure`; `cancelled` is a superseded run and does not count. Earlier runs on the same branch name belong to an older PR and are left out. The scorecard sums them per session; the headline sums them over the window.
- **Review.** `agentctl-run --role review` with `AGENT_AUTHOR_FAMILY=anthropic`: the role pins `reasoning (deepseek-v4-pro)` and refuses to start on the author's family, and every fleet session is Claude, so a review can never be Claude marking Claude. The reviewer gets the kb-reviewer rubric and the diff, may read but not write, and must answer one `FINDING <BLOCK|FLAG|NIT> <file>:<line> <defect>` line per finding, then `REVIEW DONE`. Only those lines are counted. A run that exits non-zero or never says `REVIEW DONE` is `status: failed`, never a clean review. Each PR is reviewed once.
- **Ask rank.** An ask whose session is live ranks by age in hours x (1 + phases left in that session's plan + 1 if the session has an open PR), highest first: an old ask holding a long plan comes before a new one holding nothing. The rest have no live session behind them (headless asks from the wave and delivery loops, and asks whose session has ended). They are listed oldest first and never paged one by one, because ranking them by age alone would put the same stale asks at the top of every page. On 2026-10-28, 11 of 16 pending asks were of that kind, 10 of them 35 to 61 days old.
- `project` is the tmux target with the server, the window and any `-agent-N` removed, so every `unity-core-playground-agent-*` session shares one project median.

A hand-made estimate can be added as a line in `estimates.jsonl` with `basis: "shepherd-guess"` and the same fields. It is scored like any other. The first five, from the 2026-10-27 evening summary, are there.

## Outcomes

Each runner publishes under its own name (`$AGENTCTL_NAME`) through `agent-proof.sh`'s `proof_report`.

- `sample`: WORKED when it wrote lines, NOOP when no session is live, STALLED with exit 1 when `fleet-sessions` failed. On STALLED nothing is written: the history gets a gap, and every number around it stays correct.
- `asks --page`: WORKED when it paged, NOOP when nothing is pending (`asks.md` still rewritten, so it never shows a stale list), STALLED with exit 1 when `agent-ask list` failed or `asks.md` could not be written.
- `review`: WORKED when it counted or reviewed something (the detail says `review off` while there is no route), NOOP when nothing new merged, STALLED with exit 1 when `gh` failed while counting or any review failed.

## The review route

`fleet-review.conf` sets `ROUTE=gateway-review` (private overlay, `routes/gateway-review.route`): the home LiteLLM gateway, with a key that may call only the `review` role's pinned model, `reasoning (deepseek-v4-pro)`, under the `lazer-pool` team and capped at $20 per 30 days. The key lives at `~/.local/state/agentctl/fleet-review/key` and was minted per home-config `apps/litellm/README.md` "Create a key". The pin moved off local Qwen on 2026-10-28 for a stronger reviewer that does not depend on the Mac Studio. The route is only family-safe while that model has no entry in the gateway's `router_settings.fallbacks`. Check it with `AGENT_AUTHOR_FAMILY=anthropic ROUTE=gateway-review agentctl-run --explain review`; with no `ROUTE` the runner only counts CI and the detail says `review off`.

## Cost

The sampler, the scorecard, the CI count and the ask digest call no model. They use no Claude subscription usage and no gateway allowance. The review spends a little of the Lazer allowance: at most five model runs a night, each capped at `BENCH_REVIEW_TIMEOUT_S` (900 s).

## Do NOT

- Read a score as a grade of the session. A long ratio usually means the plan's phases were uneven or the session waited on the human, which the samples' `bucket` field shows.
- Edit `progress.jsonl` to fix a number. Fix the sampler. The history is the source every number is rebuilt from.
- Add a model call to `sample`. Judgment belongs in a separate runner that reads these files.
- Point the review at a Claude model to get it running. A same-family review is recorded as independent while it is not; the `review` role refuses it on purpose.

## Related

- `fleet-overseer`: the shepherd. Its summary reads `fleet-bench eta`, and `fleet-sessions` (which it owns) is this skill's input.
- `agentctl-session-outcomes` (DREAMING.md "Session outcomes"): PRs, reverts, corrections and cost per ended session. The bench joins it by `session_id`; it does not count those again.
