---
name: day-log
description: >-
  What a day or week shipped, and a review of it (was drift-audit): merged PRs by area, what waits on the human, spend, gaps and drift. Use for "what got done today", "daily summary", "what moved this week", "review yesterday's work", "what landed #N". ETAs: fleet-bench.
metadata:
  category: monitoring
  tags: [fleet, prs, daily, history, observability, audit, retrospective]
  system: [telemetry, dispatch]
  reviewed: "2026-11-21"
---

# day-log

Answers "what did the day produce" from one record per day, so a chat answer, the hub Log tab, the notes ref and an Artifact page all say the same thing. The producer is `day-log` (`~/.local/bin/day-log`); this skill only reads it.

## Scope and triggers

What a day shipped, from the day-log record: every PR merged in any repo grouped by area and scope, the work item that landed each one (the agent-queue item whose `pr:` it is), what is still open, what waits on the human (NIGHTLY reds, NEEDS sessions, pending asks), the fleet-bench scorecard, and spend. One JSON record per local day under ~/.agent/daylog, gathered by `day-log` with no model; the hub's Log tab (Prefix i, then 7) shows the same data, and `day-log.timer` snapshots it every 5 minutes. Use when the user asks "what got done today", "what did we ship yesterday", "summary of the day", "what merged this week", "show me the day log", "which session landed #N", or wants the day as a shareable page. Not for live session state (the hub Fleet tab, shepherd status), not for ETAs or the scorecard's method (fleet-bench), and not for one session's history after it ended (session-outcomes).

- The user asks what got done, merged or shipped today, yesterday, or on a given date.
- The user asks for the week or what moved: `day-log week`, a table of 7 finished days against the 7 before (`--line` is the one-liner fleet-bench shows, `--json` the data, `--date D` a week ending on D).
- The user wants the day as a page to look at or share.
- The user wants a judgment on a day or week of many-session work, not only the list: what crept in, what was left half-done, gaps, source-of-truth breaks ("review yesterday's work", "how did yesterday go", "drift audit on <repo>"). That is the Review section below.

Not for what sessions are doing right now (`shepherd status`, the hub Sessions tab), how the scorecard is computed (`fleet-bench`), a single-PR review (`code-review`), a functional bug hunt (`bug-bash`), or whole-repo health with no window (`stack-review`).

## Steps

1. Read the record. `day-log json` gathers today fresh (about 5 s; PRs come from the PR store, `schedules-sync prs`). `day-log json --date YYYY-MM-DD` reads a past day; if it says `no record`, run `day-log snapshot --date YYYY-MM-DD` to gather it (merged PRs and spend come back; the live sections stay empty for a day nobody watched).
2. Check `.unreadable` first. A name there (`PR store merged`, `PR store stale: <repos>`, `agent-queue: ...`, `ci <repo> ...`) means that part is the last good copy, not current; say so.
3. Answer in the status shape (`comms-standard`, the shape `day-log show` prints): the headline (merged count, repos, spend), then Done (each area with its notable PRs), Doing (open PRs), Next (each live session's next plan phase) and Needs you, then the scorecard headline (`.bench.headline`, quote it as is). Name the session that landed a PR from `.by` only when it is set.
4. For a page, publish an Artifact built from the same JSON (one section per area, every PR linked), so it cannot disagree with the board.

Record fields: `merged[]` (repo, number, title, url, merged_at, scope (the item's area, else the title's scope), group, area, by (the item slug, null when no item carries the PR), author (harness:model of who wrote it: the item's own run, or the trainee's pair for a diff a batch review or a lander landed; null with no item), reviewer (who landed a trainee's diff, else null)), `trainee[]` (every trainee row closed that day, plus the rows waiting for review while the day is live: row, slug, author (the trainee's pair), outcome (merged, waiting_review, sent_back, failed), reviewer, pr, why), `open[]` (repo, number, title, created_at, updated_at, draft, area, ci, by), `next[]` (area, who, phase, done, total: each unfinished session's next plan phase, from the last live gather), `waiting` (main, needs, asks), `fleet` (sessions: the Sessions card figures headline, working, need_you, stalled and ready_to_close, "?" when unread; holds; unity_runs; a day stored before ar-4475 has a count and `buckets` instead), `done` (shipped, checks: the Done today card's queue items closed with and without a merge, read while the day is live, a part left out when unread; the record's own PRs merged count is `merged[]`, which that card reads), `bench` (headline, sessions), `usage[]` (project, sessions, tokens, cost_usd; its TOTAL row adds cash_usd and burn_usd, the fleet cost's API cash and subscription burn), `timeline[]`, `unreadable[]`, `live`, and the three sections below.

## The snapshot schema

The data feed for pipeline evaluation (queue item session-pipeline-eval): read these rather than measuring again. Schema 2, `.local/lib/day-log-snapshots.py`. A null is "not read yet", never zero. Records before 2026-11-04 do not have them; nothing backfills.

- `work.queue`: `agent-queue stats --flow` for the local day: queued, started, waiting, done, ok, failed, cancelled, and `lead_minutes`, `wait_minutes` (from ready: queued, or its `after:` item's finish when later), `run_minutes` as {n, p50, p90}.
- `work.by_agent`: per harness:model, {merged, waiting_review, sent_back, failed}, from `merged[]` and `trainee[]` (the queue item is the one source: `.agent`, `.model`, `.trainee`, `.pr_owner`, and the `trainee-batch` item that lists the row is its reviewer). A row sent back is Claude's work from then on: the pair counts sent_back, and Claude's PR counts merged. Merged counts on the day the PR merged; waiting review, sent back and failed count on the day the item closes. `day-log show` prints it as the "By agent" table with the 7 days to the day in brackets (`day-log-snapshots.py agents --date D`; waiting review is the day's own), and `day-log week` carries `agent.<harness:model>.<column>` metrics.
- `work.merges`: by_repo, by_area. `work.board`: opened, closed, open_end across every agent sheet, joined on row id, so null before ids (2026-11-04). `work.phases`: `fleet-bench flow` ticked, added, removed, started.
- `work.stages`: `fleet-sessions stages --json` for the day, replayed from the shepherd's watch.log: minutes and episodes {n, p50, p90, open} per stage and per wait reason (`NEEDS:ask`, `NEEDS:prompt`, `NEEDS:plan_approval`, `STALLED:ci_red`, `STALLED:conflict` and so on), `ci` (started, rerun_after_red, rerun_after_green), `prs.open_to_merged`, `conflicts`, `plans` (phases ticked, unticked, added, removed, minutes_per_tick), `wind_down`, sessions ended with no PR seen, and `by_project`. Records before 2026-11-05 do not have it.
- `agents`: sessions, tokens, cost_usd (the fleet cost, agent-usage fleet-cost), merged_prs, cost_per_merged_pr, by_kind, by_account from the nightly token-usage snapshot; `outcomes` (sessions, no_pr, no_pr_with_edits, no_pr_cost_usd, prs_merged, reverted_7d, interrupts, hard_errors, time_use) for a finished day; `asks` (open, age_h_p50, age_h_max) from the last live gather; `runners` {from, to, passes[]}: every agentctl runner pass that started from 20:00 the day before to 07:00, each {at, name, verdict, cost_usd, effect, score} from runs.jsonl, the calls.jsonl calls it or its CALLER calls made while it ran, its conf's EFFECT and judge-eval's `score_7d` text (`?` when judge-eval was unreadable). It is the one home of last night's rollup: `show` prints it under Flow, the briefing links it.
- `ci.repos[<owner/name>]`: `ci-failures` (runs, red, pending, cancelled, partial and `partial_why`, the read that failed, buckets; its `forgejo` repos are left out, their runs are only in the `schedules-sync` ledger), `hub ci pass` as `pass` {runs, green, pass} and `workflows` {runs, green, pass} (the one pass rate, hub_core `builds::verdict`: green over green plus red, each attempt a run, cancelled and skipped left out; `DAYLOG_HUB_CMD` overrides `hub`), `hub ci pass --branch <base>` as `main` {runs, red: runs less green} on the base branch `schedules-sync repos` names; and, where the repo has `scripts/ci/ci-cost.py`, its `--json` as `cost` (gate wall and runner minutes, queue, hours, regates, nightly, local, quarantine). Written once by `day-log nightly`; the repos are the GitHub ones `schedules-sync repos` lists (the exporter feed's, with bases and clones from the project map).
- `weeks/<D>.json`: `metrics.<name>` {value, prev, delta, pct, days, prev_days} and `line`. A sum adds days, a p50 or p90 is the median of daily values, a gauge is its last value, a ratio comes from the sums, sessions are one read over the window, cost adds the days' fleet cost. `delta` is null unless both weeks read the metric on as many days. `day_log_rollup.prom` (`agent_ci_*`, `agent_usage_*`, `agent_phases_ticked`, `agent_week_*`; the chain steps are `fleet-bench pipeline`'s `agent_chain_*`) carries the last finished day and the week.

ETA accuracy stays in fleet-bench; the record copies its headline.

The board is the hub's Log tab (Prefix i, then 6; `hub:board`): every section in full, scrolled with j/k, space, g/G, `n`/`N` jumping between sections, `[`/`]` stepping days; `h` lists every recorded day. `hub --once --tab log` prints it as text. `day-log show` prints the same record as markdown.

## Review: judge a day or week

Answers three questions about a window of many-session work: what changed (a narrative by workstream), what it left behind (drift, dirty code, source-of-truth breaks, ranked) and what is missing (gaps, each filed as one outbox line). Then it does the obvious safe cleanup and reports the rest.

Inputs: the window ("yesterday" or a date is one day; "last week" or N days, default 7), converted to absolute dates and stated; the scope, every repo in the window's records unless a repo is named; the project key from `~/.dotfiles-private/.config/shared-hooks/project-map.json` (a fleet-wide run uses `dotfiles`, so each run finds the last as its baseline). Artifacts go to `~/.agent/evals/{project}/drift-audit-{YYYY-MM-DD}/` as `week-in-review.md` (narrative by workstream) and `findings.md` (severity-ranked, file:line, CONFIRMED / REPORTED / FIXED), never inside the target repo.

1. **Gather the window** from the record: `day-log json --date D` per day (`work` and `merged` for what landed, `open` with age, `agents` and `ci` for waste) and `day-log week --date D`. Churn and reversals: `git log --since --name-only` per repo, files touched by 3 or more PRs, revert or "back out" subjects. Repo state: `git branch -vv` (behind, `[gone]`), `git stash list`, worktrees. Branch any cleanup off `origin/main`.
2. **Baseline.** The newest `~/.agent/evals/{project}/drift-audit-*` or `stack-review-*` dir (a letter suffix is a later run that day): every earlier finding in its `findings.md` or `report.md` is FIXED, STILL OPEN or GONE. Lead with what changed since; with no dir, say there is no baseline.
3. **Fan out**, one Explore agent per dimension, concurrently, each brief in `references/day-review-briefs.md`: workstreams, churn and source-of-truth breaks in the fleet repos; code drift and repo hygiene; other repos and the open-PR backlog; process waste. For an independent read of a high-stakes area, add a `blind-review` run.
4. **Artifact check, then verify.** Before calling a number bad, check for a counting artifact: one deliberate drain or bulk cancel, headless runners (which never open PRs) inside the no-PR sessions, board rows that left the sheet without a check, a level change read as a rate change. Never trust an agent's high-severity finding unverified: re-run the grep, read the file:line. Two house patterns are not drift: a code default plus a conf override that agree, and a `rules.jsonl` row naming a knob by anchor.
5. **Write the docs and the answer.** `week-in-review.md` groups every change into workstreams with their PRs and closes with the most important signal. `findings.md`: baseline table first, then P0 (real bug or process breach), P1, P2 (hygiene), git hygiene; a "done multiple ways" section; an executed-vs-reported ledger. Answer in the `comms-standard` status shape: what changed since the baseline, the top findings, what was executed (PR links), what waits on the human.
6. **Split safe cleanup from report.** Execute only the unambiguous, low-risk fixes (a dead knob, a stale doc row, a copied number replaced by a link) on a branch off `origin/main`, tested, landed per `dotfiles-land`. Anything on shared history, stash drops, branch deletes, mechanism merges that need caller migration, or CI-cost trades is one `notes ptask <project> --agent add` line each, never a board row written directly.
7. **Hand off.** Durable patterns go to `~/.agent/lessons/{project}.md`; delete the scratch the run and its agents left. Fold new dimensions and artifact traps into this section and the briefs.

## Do NOT

- Do not call `gh` yourself to count the day. Two producers drift; a scope or bound fix belongs in `day-log`, and grouping belongs in `~/.config/day-log/groups`.
- Do not read `usage` cost as the day's spend. It is the whole-session spend of every session active that day, so a session that ran for three days counts in full on each. The same goes for `agents.cost_usd`: for a week use `day-log week`.
- Do not recompute scorecard numbers. `bench` is `fleet-bench`'s own output, copied.
- Do not report a P0 you did not verify first-hand, a raw count you did not check for an artifact, or a raw commit dump in place of a workstream narrative; do not commit a Review's cleanup onto a docs or throwaway branch.
