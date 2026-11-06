---
name: fleet-bench
description: >-
  Benchmark the agent fleet from counted facts: ETAs and their accuracy, scorecard, KPIs, blocking asks. Use for "when will agent-N be done", "show me the scorecard", "what is waiting on me". Load: fleet-pace.
metadata:
  category: monitoring
  tags: [agents, fleet, benchmark, estimates, observability]
  reviewed: 2026-11-05
---

# fleet-bench

On 2026-10-27 the shepherd told the human when each session would finish ("about 9:00 PM", "tomorrow around midday") by assuming one phase per hour. Nothing kept those numbers and nothing checked them. The first one scored, an hour later, took up to 2.6x as long as predicted. This skill is the record and the check. It is a component of its own, like `fleet-dispatch`: the shepherd only reads it.

Every number here is counted from samples. None is a model's grade, because model-graded evals on this fleet read 10/10 almost every time and rank nothing.

## Scope and triggers

Benchmark the agent fleet from counted facts: where every live session is in its plan, when it should finish, and afterwards how far off that prediction was. Verbs: findings | respond | loop | throughput | flow | forecast | vs | queue | requests | report | effect | eta | headline | scorecard | sessions | stats | sample | review | asks | ledger | kpi | retro | triage. Use when the user asks "how accurate are the ETAs", "when will agent-N be done", "when will the fleet be done", "what order will the work land in", "how did today go against the forecast", "is work coming in faster than it gets done", "benchmark the sessions", "how fast is the fleet moving", "show me the scorecard", "how often does CI go red before merge", "how long do queue items wait", "how many queue items reached a PR this week", "review a sample of merged PRs", "which asks are blocking", "what is waiting on me", "did anything act on that alert", or when the shepherd writes a "where are we" summary and needs an ETA per session. Model-free except `review`, which runs a non-Claude model (deepseek-v4-pro on the Lazer allowance) through the runner's route. Not for load or holds (fleet-pace) and not for what one session did after it ended (session-outcomes).

## Where to look

- `~/.notes/lab/projects/current/agent-runtime/docs/bench/latest.md`: the daily scorecard, one row per session over the last 24h (phase now, phases ticked, hours working, hours waiting on you, hours stalled, nudges, peak context, then PRs merged, CI reds, reverts and cost). One dated file per day sits beside it. It syncs with notes, so it reads on the phone.
- The morning briefing (`agentctl-briefing`, 06:45) writes the scorecard, puts the headline and its path in `briefing.md`, and carries the pending-asks line in its one page.
- `~/.notes/lab/projects/current/agent-runtime/docs/bench/asks.md`: every pending ask, the ones blocking a live session first, rewritten by the briefing at 06:45 and 18:45. The 18:45 run pages it on its own (`-t asks`), naming the top three and what each session recommends.
- `fleet-bench report`: every live session (phase done/total, bucket, ETA, what the ETA is based on), then how accurate past ETAs were, then the last agentctl outcome of `fleet-bench`, `fleet-review` and `briefing`.
- `fleet-bench eta`: one line per live session, or `--json` for scripts. The shepherd's "where are we" summary takes its ETAs from here.
- `fleet-bench requests [--json] [--since T]`: the human's urgent requests from the queue, a plan chain as one row, then what finished since T (default: the last rundown). The one home of that grouping: a view reads `--json`, never its own copy. Fields and order: `REQUESTS_JQ` in the script.
- `fleet-bench forecast`: when the whole fleet should be done, the drain, and the next phases in order. The scorecard's "Forecast" section carries it, plus `vs` against the newest baseline at least an hour old (at 06:45 that is yesterday's `daily-<date>`). The briefing freezes `daily-<date>` before it writes the scorecard.
- Prefix + Ctrl-g (`fleet.sh`) has a `bench` section under the asks: the headline, then one ETA row per live session. Its runners section lists `fleet-bench` and `briefing` with every other agentctl unit, red when the last outcome is STALLED or the run failed.
- `agentctl status fleet-bench` and `agentctl logs fleet-bench -f` for one run's detail.

## Verbs

- `sample`: one pass. It reads `fleet-sessions --json`, appends one line per live session to `progress.jsonl`, writes an estimate for any session whose phase count has no estimate yet, and scores every estimate whose session has since finished. The agentctl runner `fleet-bench` runs it every 10 minutes: `fleet-sessions` has no event to wait on, so this is a steady poll, and one run costs about 14 s, mostly `gh`.
- `eta [--json]`: the newest estimate per live session from the newest sample, calibrated when its basis has enough scores (see "How the numbers are made"). A finished session has none. Once the newest sample is past the ETA, the row reads `late 2.4h` instead of a time, and the estimate itself stays as it was. `--json` gives `eta`/`eta_epoch` (the ETA shown, calibrated when it was), `raw_eta_epoch`, `factor`, `late_min` (minutes past it, null when not late) and `basis`.
- `report`: as above. Read-only.
- `accuracy --json`: one object per basis kind from `scores.jsonl`: `basis`, `n` (scored), `n_ratio` (scored with a ratio), `median_ratio`, `median_error_min`, `median_abs_error_min`, and `factor`, the calibration a new estimate of that kind gets now (null below the minimum). The same function makes the factor and the report's per-basis lines, so all three always agree. The watch board's ETA trust line reads it.
- `headline`: the last `BENCH_WINDOW_H` (24) hours in one line: sessions, phases ticked, hours waiting on you, hours stalled, ETAs scored and their median raw ratio, and the calibrated ones' median ratio when any were scored.
- `scorecard`: writes `<date>.md` and `latest.md` in `BENCH_SCORECARD_DIR` and prints the path. Sections: KPIs; Bottlenecks (hours lost per queue, on runs not passed, waiting on you and stalled, biggest first, then the branches behind the failed runs); Where the time went (per project and plan, with 24h spend and merges); Sessions; Agent depth (test runs, CI polls, tool errors and tokens past the last edit, from session-outcomes' `activity`); Session time (hours per project over `BENCH_TIME_DAYS` by what was running: work, gate, test, other jobs, you, parked, from session-outcomes' `time_use`); Queue (the `queue` line, what is active now, done per day, and outcomes by project and by source); Models (the `models` table); ETA accuracy; Consolidation ledger. A source that cannot be read shows `?` or says so; it is never left out.
- `stats --json [--since E]`: one object per session sampled, or merging a PR in `pr-ci.jsonl`, since epoch E (default: all of it), over its whole life rather than the 24h window: `minutes` per bucket (the same gap rule as the scorecard hours), `nudges`, `escalations` (each time the flag turns on), `ticked`, `peak_context`, `first_epoch` and `last_epoch`, and `merged` {prs, lines_added, lines_deleted, ci_runs, ci_reds}, null when it merged nothing. `sampled: false` marks a session only `pr-ci.jsonl` knows. `agentctl-session-outcomes` stores each row as its row's `delivery`, so `card` and `worst` read it there.
- `review`: for every PR that session-outcomes lists as merged in the window and `pr-ci.jsonl` has not counted, one `gh pr view` and one `gh run list --branch` give its size and its CI runs from its first commit to merge. No model reads the diff: the model review was dropped on 2026-11-02 after 310 of 312 runs failed on the gateway key's budget. The agentctl runner `fleet-review` runs it at 02:45, after session-outcomes (02:30) and before the 06:45 scorecard.

- `asks [--write|--page]`: every pending ask from `agent-ask list --all --pending`, joined to the newest sample of the session its `session` field names (a session id or a tmux session name). It prints the digest; `--write` also writes `asks.md` in `BENCH_SCORECARD_DIR` and prints the one-line summary (counts and the top three) with no page and no verdict, for the morning briefing to carry; `--page` writes `asks.md` and sends that line as one `agent-notify -p normal -t asks` page, which the briefing's 18:45 run does.

- `ledger [--json|--check]`: the consolidation ledger. It counts runner confs (`runners`, `runners_on` without `ENABLED=no`), generated `agentctl-*.timer` files, files with a direct headless `claude -p|--print` outside agentctl-run (`launches_direct`, gitignored build output skipped), distinct `last-outcome` verdicts, pending asks and those older than `ASK_STALE_DAYS` (14), and open agent-board rows. `--check` prints each of `runners`, `timers` and `launches_direct` that is over `~/.config/agentctl/ledger-baseline` and exits 1 (2 with no baseline). To add a runner, timer or launch, retire one or raise the baseline in the same PR with a why. The scorecard carries the counts and the check under "Consolidation ledger". `--launches DIR...` prints the scan's matches; `runner_contract.bats` uses it.

- `kpi [--json] [--at T | --trend DAYS]`: the KPI table over the last 7 and 28 days (`| KPI | 7d | 28d | threshold | status |`), or one JSON object keyed by KPI; the scorecard carries it under "KPIs", right after the headline. `--at T` evaluates both windows as of a past time (the comms and counted-now KPIs read null, since nothing records them as of then). `--trend N` prints one row a day of the 7d windowed KPIs, oldest first. The outcome rows are the history, so neither keeps a store of its own.
- `chain [--json|--check]`: the work-chain rows of the KPI table (the `KPI_CHAIN` keys below), counted now; `--check` prints `<kpi> <value> (<bound> <threshold>)` for each one past its threshold and exits 1, which is the probe of the `board-chain` Sentinel watch. A source that cannot be read leaves its KPI `-`, never past.
- `pipeline [--json]`: where every item sits, inbox -> backlog (open agent rows no item started) -> queued -> running -> waiting -> done (finished in 24h). WIP and age (p50, p90, oldest) come from the state files; in and out over 1h and 24h and the dwell of what left come from `notes log --steps --json` (`BENCH_STEPS_CMD`), which owns the record's schema. The bottleneck is the step whose age p90 is furthest past its `step_age_p90_<step>_max`, none while all are inside; steps taking in more than they let out over 24h are listed as growing. The same numbers are the `agent_chain_*` gauges in `fleet_bench.prom` (Grafana's Pipeline row).
- `effect <T | owner/repo#N> [--days N] [--json]`: each windowed KPI over the N days (default 14) up to a change against the N days after it, where a PR is read as its merge time. The verdict per KPI is improved or regressed when it moved more than `BENCH_EFFECT_FLAT` (10%) in the direction that is better for it, flat inside that, and pending until the after window has ended. Many changes land in any window, so a verdict is a lead to look at, never proof that one change did it.

- `retro`: for each KPI whose 7d value is past its threshold, keeps exactly one open row `kpi: <key> past threshold: 7d <v> (28d <v>, max <t>)` on the agent-runtime agent board (`now <v> (max <t>)` for a count taken now): it adds the row (`#high` when more than 2x past, else `#low`) or refreshes its numbers with `ptask edit`, and touches no other row. It keeps one `guard <hash>:` row the same way for each lesson whose `<!-- sig:YYYY-MM-DD <regex> -->` matched Bash commands in `BENCH_GUARD_RECUR` (default 2) or more sessions after its date (session-outcomes `lesson_hits`), `#high` at twice that; the row asks for a hook, test or lint and for the lesson to be deleted once it lands. WORKED when it wrote, NOOP otherwise; with no thresholds file it checks no KPI but still checks lessons. The briefing runs it on Mondays.
- `triage [--dry-run]`: one open agent-board row per runtime fault, through the same upsert as `retro` (key prefix, refreshed in place, `#size/s`): `fix(runner): <name> is <VERDICT>: <date> <detail>` for a scheduled runner whose `last-outcome` is FAILED (`#high`) or STALLED (`#low`); `fix(unit): <unit> failed: <Result>` for each failed user unit (`#high`); `check(watch): <name> tripped since <date>, expected: <what>` for a Sentinel watch held at TRIP for `TRIAGE_WATCH_AFTER` (6h) or more, `#high` at severity high or urgent. A row whose fault cleared is closed by whoever fixes it. `--dry-run` prints the rows and writes nothing. The briefing runs it daily.

- `findings [--open|--json|--run]`: conclusions that want a decision, from rules over counted facts on every machine. It prints what is open, worst class first; `--json` gives the rows; `--run` evaluates and appends, and every `sample` does. See "Findings".

- `respond '<rule> <scope> @<episode>' <actor> <action> [ref]`: appends one row to `responses.jsonl` saying what answered a finding, keyed by its `fact`. Actions: `paged` (written by `fleet-sessions escalate` when a finding goes to the human), `asked`, `filed-row`, `cancelled`, `fixed`. A bad fact or action exits 2.

- `loop [--json|--firing]`: every finding episode of the last 7d seen on two samples or more, report class left out: minutes from the episode to its first response that is not a page, whether it still fires, and the responses in order. An episode that reached class human with only pages is `DARK`: the loop saw it and nothing acted. The header gives the counts and the median first response; `prom` publishes `agent_bench_loop_dark_episodes` and `agent_bench_loop_first_response_minutes`. `--firing` prints one sentence per dark episode still firing, which the daily briefing puts under Needs you.

- `flow [--from T] [--to T] [--json] [--hourly]`: phases in against phases out over the window (default `BENCH_WINDOW_H`). It counts phases ticked, phases added and removed by plan edits, and plans started with their open phases, then the open phases at each end and those left by plans that ended or were switched away from. The last line says `draining N/h` or `not draining (in X/h, out Y/h)`. `--hourly` gives the burn-up: cumulative scope and done per hour.

- `forecast [--json] [--queue] [--baseline <label>]`: every open phase of every live session that has a plan and an estimate, scheduled in plan order. It prints the fleet's all-done-by (median, p90 and last session finish) at both ends of the band, the drain, and the next 10 phases in expected order. Phases already past their estimate are counted as "due now". It always reads the agent queue too (`agent-queue list --json --state active`, `BENCH_ITEMS_CMD`) and puts its items on the dispatch slots (see "How the numbers are made"), as an `agent queue:` line with its own all-done-by and as `queue:<project>  <slug>` rows in the next-phases list; an unreadable queue says so and leaves the items out. `--queue` adds the rows `fleet-dispatch fill --dry-run` would promote next (about 24 s), times the median phases per plan, as a separate "queued after this" line. `--baseline <label>` freezes the whole object, queue included, as one line in `forecasts.jsonl`.

- `vs [<label>|latest] [--json]`: a frozen forecast against what happened since. It gives phases ticked against those expected by now, each baseline session finished, ahead, on track, behind or gone (behind and ahead come with minutes), scope added to baseline plans, new plans, sessions started since, and inflow now against inflow when frozen.

- `queue [--json]`: the agent queue over the last `BENCH_QUEUE_DAYS` (7) days in one line: items done by outcome (ok, failed, cancelled), how many recorded a PR, done per day, the wait (queued to started) median and p90 over items that waited, with the items that started at once counted apart (a `--running` or plan item would otherwise read as a 0 min wait), the median time to PR (queued to finished, for items with a `pr:`), and what sits now: how many queued items could start, the oldest one's age, and how many are held. Every number is `agent-queue stats --json --since <date>` (seam `BENCH_QUEUE_STATS_CMD`), which owns the store and the formulas; `--json` passes that object through, with `by_project` and `by_source` (human, shepherd, board and so on) carrying the same outcomes each. The briefing carries the line, and the scorecard's "Queue" section the tables. Unreadable: exit 1, and `?` in the scorecard.

- `models [--json]`: per model, the queue items finished in the last `BENCH_QUEUE_DAYS` days by the `model:` fleet-dispatch stamped at start (`unrecorded` before it did), cancelled ones left out: done, landed (done ok with a `pr:`) and landed rate, failed, then reverts and cost summed over the newest session-outcomes row of each session in the item's `sessions:`, and cost per landed PR. Redo comes from model-lane's log (`BENCH_LANE_LOG`, `~/.agent/model-lane/runs.jsonl`): runs in the window on that model, how many have an outcome, and the share of those that were redo (a started item put back in the queue). The scorecard's "Models" section is the same table. This is what a lane graduates or demotes on; the demote itself is `model-lane`'s.
- `throughput [--from T] [--to T]`: runs/h, share not passed, editor-hours and those spent on runs not passed, merges/h per project, each pool's queue, and load per core on every host over 0.5x. Default window is the last 2h; T is an epoch or anything `date -d` reads. Any slot, hold or pace change states this number before and after. Read-only apart from a `git fetch` of each project's default branch.

### Findings

`fleet-assess` decides for this workstation alone. Findings read the pool and the other hosts too, and they are in shadow: nothing pages on them yet (plan `can-we-update-shepherd-composed-hopcroft`).

| Rule | Fires when | Reads | Class |
|---|---|---|---|
| `starved <host>` | `finding_queued_min` (5) local runs queued on 2 samples and the CPU over `finding_local_idle_min` (0.3) idle | `cc:host_local_queued`, `cc:host_cpu_busy_ratio` | shepherd, human after `finding_human_after_min` (60) |
| `starved pool:<pool>` | oldest job waited `finding_pool_wait_s` (3600) with jobs still waiting. Busy share under `finding_pool_idle_share` (0.75) concludes admission or labels, otherwise demand over capacity. `repos` names the repos whose jobs wait (`github_actions_job_waiting` by pool, repo), null when unread | `cc:pool_*` | shepherd, human after that |
| `throughput-drop <project>` | merges/h over 2h under `finding_merge_ratio` (0.5) of the 24h rate, with a 24h rate of at least `finding_merge_floor_h` (2)/h, while live sessions hold at `finding_demand_ratio` (0.7) of their 24h average | `git log --first-parent`, `progress.jsonl` | human |
| `host-overload <host>` | load per core at `finding_host_load_per_core` (2) on 3 samples | `cc:host_load1`, `cc:host_cores` | report, human after that |
| `blind <source>` | Prometheus unreadable, a series missing, a project's merges unreadable (no mapped repo, or the fetch failed; a worktree name like `unity-core-playground-agent-40-b` maps by its longest registered `<repo>-` prefix), the rules themselves failing, or nothing evaluated within `finding_clear_min` | every source | report |

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
| `plan_gate_deny_rate` | sum `plan_gate.denied` / sum `plan_gate.exits`. No threshold: near 1 means the posture is not landing, near 0 with thin sections means the gate is too easy |
| `cost_per_pr` | sum `cost_usd` / sum `prs_merged` |
| `ci_red_per_pr` | sum `ci_red` / rows in `pr-ci.jsonl` by `merged_epoch`, headless sessions' PRs left out |
| `human_answered_per_day` | asks answered by a human (`answered_by` human or empty) with `answered_at` in the window / its days, from `agent-ask list --all` |
| `ask_wait_p90_min` | p90 minutes from `created` to answered or closed, still-open asks counted to now; cancelled asks left out. Replaced `asks_stale`, which stays a ledger count |
| `runners_bad` (now) | switched-on runner confs whose `last-outcome` is FAILED or STALLED (also in `ledger`) |
| `board_open` (now) | the ledger's `board_open` |
| `loop_dark` (now) | finding episodes of the last 7d still firing that reached class human with no response but a page (`loop`) |
| `ledger_coverage` (now) | PRs merged in the last `CHAIN_DAYS` (7) in `pr-ci.jsonl` that an active or done item's `pr` names (`owner/repo#N` or a forge URL by repo, a bare `N` by number) / all of them |
| `untracked_merged_prs` (now) | those same PRs no item names |
| `board_orphan_started` (now) | started (`[/]`) agent rows in `notes board --json` that no active item's `row` names |
| `merged_open_rows` (now) | items done in the window with `merged:` whose row is still open |
| `ownerless_running` (now) | running items with neither `session` nor `sessions` |
| `epic_linked_share` (now) | open agent rows filed under an epic (`#of/`) / open agent rows, in projects with an open epic (`notes projects --stats --json`) |
| `landed_unverified` (now) | open epics whose every leaf is done: landed, waiting on proof of the outcome |
| `doctor_fail` (now) | `FAIL` lines in the last `notes doctor` run (`BENCH_DOCTOR_LAST`) |
| `chain_drift` (now) | queue items the record and the queue folders place apart: at another step, held by the record but gone from the queue, or queued after the record's `items_since` with no event. Work older than `items_since` is not counted |
| `step_age_p90_<step>` (now) | `pipeline`'s age p90 in minutes for backlog, queued, running and waiting |

Thresholds are data in `KPI_THRESHOLDS` (default `~/.config/agentctl/kpi-thresholds`, private overlay), one `<kpi>_max=` or `<kpi>_min=` line each. A KPI with no line has status `-`; a missing file leaves every status `-` and `retro` files no KPI row.

Under the table the scorecard prints two lines from `agent-usage wakes --since <window>h --json` (seam `BENCH_WAKES_CMD`): calls per passing wake (the median calls of a background-task wake whose run passed, `past` above `WAKE_CALLS_TARGET`, default 2) and calls per wake over every trigger (median, p90). Each API call re-reads the whole context, so calls per wake is the cost; a source that cannot be read prints `?`.

## How the numbers are made

State is in `~/.agent/bench/` (override with `FLEET_BENCH_DIR`).

| File | One line per | Fields that matter |
|---|---|---|
| `progress.jsonl` | session per sample | `epoch`, `session_id`, `target`, `project`, `bucket`, `phases_done`, `phases_total`, `finished`, `idle_min`, `context_tokens`, `nudged` |
| `estimates.jsonl` | session per phase count | `made_epoch`, `eta_epoch` (raw), `per_phase_min`, `basis`; when calibrated also `factor`, `factor_n`, `cal_eta_epoch` |
| `scores.jsonl` | estimate whose session finished | `error_min`, `ratio` (both against the raw ETA), `horizon_min`, `done_bound`; when calibrated also `factor`, `cal_error_min`, `cal_ratio` |
| `pr-ci.jsonl` | merged PR | `repo`, `number`, `session_id`, `merged_epoch`, `additions`, `deletions`, `ci_runs`, `ci_red` |
| `forecasts.jsonl` | frozen forecast | `label`, `made_epoch`, `last_p50`/`last_slow` (and median, p90), `drain`, `queue`, `schedule[]` (per session: `phases[]` with `name`, `p50`, `slow`) |
| `forecast-scores.jsonl` | baseline once it resolved | `resolved_by`, `actual_last`, `bound`, `ratio_p50`, `ratio_slow`, `error_min`, `within_slow`, `in`, `in_per_h` against `in_per_h_frozen` |
| `findings.jsonl` | firing finding per sample | `epoch`, `rule`, `scope`, `episode`, `decision_class`, `evidence`, `conclusion`, `cost`, `fact` |
| `responses.jsonl` | act on a finding (`respond`) | `epoch`, `fact`, `actor`, `action` (paged, asked, filed-row, cancelled, fixed), `ref` |

- **Phase time.** Each plan file is its own timeline, so a session that starts a new plan does not count the switch as a phase. A phase is measured only when the samples saw both its start and its end, so a session's first phase on the record is never measured (it may have started hours earlier). When one sample sees two phases tick at once, the gap is split evenly between them. The time includes waiting on the human.
- **ETA** = now + phases left x per-phase minutes. Per-phase is the median measured phase time of that session (`basis: session-median(n)`), else of every session in its project (`project-median(n)`), else `BENCH_DEFAULT_PHASE_MIN`, 60 (`default`). A session or project needs `BENCH_BASIS_MIN_N` (3) measured phases before its median is used: on 2026-11-02 one measured phase predicted 3.5 days for a session that took 20 minutes. A new estimate is written only when the phase count changes, so one estimate stands for each step of a plan and is scored as it was made.
- **Calibration.** The raw ETA runs long or short by a measured amount per basis (on 2026-10-28 project-median ETAs took 0.3x as long as predicted), so each new estimate also gets a factor: the median raw `ratio` over every score of the same basis kind (`session-median`, `project-median`, `default`, `shepherd-guess`), counting only scores that have a ratio. It applies only once that kind has `BENCH_CAL_MIN_N` (5) of them, clamped to `BENCH_CAL_MIN` (0.25) and `BENCH_CAL_MAX` (4), and rounded to 0.01. Then `cal_eta_epoch` = made + (raw ETA - made) x factor, and every view (`eta`, `eta --json`, `report`, the bench section of Prefix + Ctrl-g, the shepherd's summary) shows it, with the basis reading for example `project-median(13) x0.3 (n=23)`. Below the minimum the raw ETA is shown and the basis has no factor. The factor is fixed when the estimate is made, so a published ETA does not move as later scores land; an estimate made before calibration existed shows raw until its session's next phase tick. The raw ETA stays in `eta_epoch` and is what `ratio` is scored against, so the factor is always made from raw ratios: scoring the calibrated ETA instead would pull the ratio to 1 and the factor would undo itself.
- **Finish** is the first sample that reads `finished` (fleet-sessions' DONE work conditions). If that was the session's first sample at all, the real finish was earlier, and the score says `done_bound: upper`.
- **Score.** `error_min` = finish - ETA (positive means it ran long). `ratio` = actual duration / predicted duration (2 means it took twice as long). `horizon_min` = how far ahead the ETA looked. A calibrated estimate is also scored against its calibrated ETA (`cal_error_min`, `cal_ratio`), so the report shows whether calibration helps. The report gives medians by basis, by basis calibrated, and by horizon (under 2h, 2-8h, over 8h).
- **Scorecard hours.** Each sample owns the time until the next sample of that session, in that sample's bucket: WORKING is working, NEEDS is waiting on you, STALLED is stalled. A gap longer than `BENCH_GAP_CAP_MIN` (20, two cadences) counts as 20 minutes, because a longer gap means the sampler itself was down. Nudges count each time the shepherd's `nudged` flag turns on. PRs merged, reverts and cost are the newest session-outcomes line for that `session_id`, `-` when it has not been observed yet.
- **CI reds.** Runs on the PR's branch from its first commit (or its opening, if earlier) to its merge. Red is `failure`, `timed_out` or `startup_failure`; `cancelled` is a superseded run and does not count. Earlier runs on the same branch name belong to an older PR and are left out. The scorecard sums them per session; the headline sums them over the window.
- **Ask rank.** An ask whose session is live ranks by age in hours x (1 + phases left in that session's plan + 1 if the session has an open PR), highest first: an old ask holding a long plan comes before a new one holding nothing. The rest have no live session behind them (headless asks from the wave and delivery loops, and asks whose session has ended). They are listed oldest first and never paged one by one, because ranking them by age alone would put the same stale asks at the top of every page. On 2026-10-28, 11 of 16 pending asks were of that kind, 10 of them 35 to 61 days old.
- **Forecast.** Each open phase of a session takes per-phase minutes x the factor of its newest estimate (the p50 end), and the same minutes x the median raw ratio of ETAs scored in the last window (the slow end, 1 when none were). The first open phase ends at the estimate's made time plus one phase, or now if that is already past, and each later phase follows one phase after it. Names come from the plan's `## Phases` checklist, through the same parser `fleet-sessions` uses, and `phase N` stands in when there is no checklist. The band is wide on purpose: on 2026-11-03 the factor was 1.16 while the last 24h ran 1.93x, and the band shows that gap instead of averaging it away. The drain is open phases / (out per hour - net in per hour) over the last window. When inflow is at or above burn, no time is given.
- **Queue items.** Each item is one phase (an item from `agent-queue add --plan` counts its `phases:`, another item naming a `plan:` that plan's open phases, a plan item with no plan the median phases per plan) at its project's median measured phase time (the project through `project-map.json` `trackers.<p>.repo`, so `dodginballs` reads `unity-core-playground`), else the fleet median, else `BENCH_DEFAULT_PHASE_MIN`, calibrated by that basis kind's factor; the slow end uses the last window's ratio. Items run on the dispatcher's slots: `BENCH_QUEUE_SLOTS`, else `DISPATCH_MAX_LIVE` from `BENCH_DISPATCH_CONF`, else fleet-dispatch's own default. A running item holds a slot until it ends; one whose session is already on the schedule ends at that session's finish and is not counted again. Each time a slot frees it goes to the first queued item in queue order whose `after:` parent has ended, else to the one ready soonest. Waiting, night- or time-held items, items after one that did not finish ok, and items behind those are listed as not scheduled with the reason, never given a time. Load gates and away-only board items are not modelled, so the item line is the best case. The item line has its own finish and does not move the all-done-by that baselines are scored on.
- **Forecast score.** A baseline resolves when every session in it has finished (it said so, or it ticked as many phases as it had open) or is gone (absent from a sample, ended at the first sample without it). Past `BENCH_FORECAST_HORIZON_H` (48) a baseline also resolves, as a lower bound with `open` counted. `ratio_p50` = (actual last finish - made) / (predicted last p50 - made). `sample` scores each baseline once. `report` prints them under "Fleet forecast accuracy". Back-test, 2026-11-03: the 2026-11-02 06:45 baseline held 5 sessions with 14 phases and was due by 13:02. After 24h, 4 of them were still open (ratio 3.8x or more), and 67 more sessions had started. Inflow was 12.75/h against 3.58/h when it was frozen.
- `project` is the tmux target with the server, the window and any `-agent-N` removed, so every `unity-core-playground-agent-*` session shares one project median.

A hand-made estimate can be added as a line in `estimates.jsonl` with `basis: "shepherd-guess"` and the same fields. It is scored like any other. The first five, from the 2026-10-27 evening summary, are there.

## Outcomes

Each runner publishes under its own name (`$AGENTCTL_NAME`) through `agent-proof.sh`'s `proof_report`.

- `sample`: WORKED when it wrote lines, NOOP when no session is live, STALLED with exit 1 when `fleet-sessions` failed. On STALLED nothing is written: the history gets a gap, and every number around it stays correct.
- `asks --page`: WORKED when it paged, NOOP when nothing is pending (`asks.md` still rewritten, so it never shows a stale list), STALLED with exit 1 when `agent-ask list` failed or `asks.md` could not be written.
- `review`: WORKED when it counted a PR, NOOP when nothing new merged, FAILED with exit 1 when `gh` failed while counting.

## Cost

The sampler, the scorecard, the CI count and the ask digest call no model. They use no Claude subscription usage and no gateway allowance.

## Do NOT

- Read a score as a grade of the session. A long ratio usually means the plan's phases were uneven or the session waited on the human, which the samples' `bucket` field shows.
- Edit `progress.jsonl` to fix a number. Fix the sampler. The history is the source every number is rebuilt from.
- Add a model call to `sample`. Judgment belongs in a separate runner that reads these files.

## Related

- `shepherd` and `fleet-lead`: the shepherd reads `fleet-sessions` (this skill's input) and its `overdue:` lines are measured against `fleet-bench eta`; the `fleet-lead` summary quotes the ETAs.
- `agentctl-session-outcomes` (DREAMING.md "Session outcomes"): PRs, reverts, corrections and cost per ended session. The bench joins it by `session_id`; it does not count those again.
