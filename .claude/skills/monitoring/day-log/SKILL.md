---
name: day-log
description: >-
  What a day shipped: merged PRs by area, the session behind each, what waits on the human, spend. Use for "what got done today", "what merged this week", "what moved this week", "which session landed #N". ETAs are fleet-bench.
metadata:
  category: monitoring
  tags: [fleet, prs, daily, history, observability]
  reviewed: "2026-11-04"
---

# day-log

Answers "what did the day produce" from one record per day, so a chat answer, the hub Today tab, the notes ref and an Artifact page all say the same thing. The producer is `day-log` (`~/.local/bin/day-log`); this skill only reads it.

## Scope and triggers

What a day shipped, from the day-log record: every PR merged in any repo grouped by area and scope, the session that landed each one, what is still open, what waits on the human (NIGHTLY reds, NEEDS sessions, pending asks), the fleet-bench scorecard, and spend. One JSON record per local day under ~/.agent/daylog, gathered by `day-log` with no model; the hub board's Today tab (Prefix O) shows the same data, and `day-log.timer` snapshots it every 5 minutes. Use when the user asks "what got done today", "what did we ship yesterday", "summary of the day", "what merged this week", "show me the day log", "which session landed #N", or wants the day as a shareable page. Not for live session state (the hub Fleet tab, shepherd status), not for ETAs or the scorecard's method (fleet-bench), and not for one session's history after it ended (session-outcomes).

## When to Use

- The user asks what got done, merged or shipped today, yesterday, or on a given date.
- The user asks for the week or what moved: `day-log week`, a table of 7 finished days against the 7 before (`--line` is the one-liner fleet-bench shows, `--json` the data, `--date D` a week ending on D).
- The user wants the day as a page to look at or share.

Not for what sessions are doing right now (`shepherd status`, the hub Fleet tab) and not for how the scorecard is computed (`fleet-bench`).

## Steps

1. Read the record. `day-log json` gathers today fresh (about 5 s, three gh searches). `day-log json --date YYYY-MM-DD` reads a past day; if it says `no record`, run `day-log snapshot --date YYYY-MM-DD` to gather it (merged PRs and spend come back; the live sections stay empty for a day nobody watched).
2. Check `.unreadable` first. A name there (`gh merged`, `agent-queue: ...`, `ci <repo> ...`) means that part is the last good copy, not current; say so.
3. Answer in prose, summary before detail: merged count and repos, then each area and group with its notable PRs, then what is open, then what waits on the human, then the scorecard headline (`.bench.headline`, quote it as is). Name the session that landed a PR from `.by` only when it is set.
4. For a page, publish an Artifact built from the same JSON (one section per area, every PR linked), so it cannot disagree with the board.

Record fields: `merged[]` (repo, number, title, url, merged_at, scope, group, area, by), `open[]` (repo, number, title, created_at, updated_at, draft, ci, by), `waiting` (main, needs, asks), `fleet` (sessions, buckets, holds, unity_runs), `bench` (headline, sessions), `usage[]` (project, sessions, tokens, cost_usd), `timeline[]`, `unreadable[]`, `live`, and the three sections below.

## The snapshot schema

The data feed for pipeline evaluation (queue item session-pipeline-eval): read these rather than measuring again. Schema 2, `.local/lib/day-log-snapshots.py`. A null is "not read yet", never zero. Records before 2026-11-04 do not have them; nothing backfills.

- `work.queue`: `agent-queue stats --flow` for the local day: queued, started, waiting, done, ok, failed, cancelled, and `lead_minutes`, `wait_minutes`, `run_minutes` as {n, p50, p90}.
- `work.merges`: by_repo, by_area. `work.board`: opened, closed, open_end across every agent sheet, joined on row id, so null before ids (2026-11-04). `work.phases`: `fleet-bench flow` ticked, added, removed, started.
- `agents`: sessions, tokens, cost_usd, merged_prs, cost_per_merged_pr, by_kind, by_account from the nightly token-usage snapshot; `outcomes` (sessions, no_pr, no_pr_with_edits, no_pr_cost_usd, prs_merged, reverted_7d, interrupts, hard_errors, time_use) for a finished day; `asks` (open, age_h_p50, age_h_max) from the last live gather.
- `ci.repos[<owner/name>]`: `ci-failures` (runs, red, red_rate, pending, cancelled, partial, buckets, `main` {runs, red}, the base branch `~/.config/agentctl/day-log-ci` names, `workflows` {runs, red, pass_rate}) and, where the repo has `scripts/ci-cost.py`, its `--json` as `cost` (gate wall and runner minutes, queue, hours, regates, nightly, local, quarantine). Written once by `day-log nightly`; the repos are `~/.dotfiles/.config/day-log/ci`.
- `weeks/<D>.json`: `metrics.<name>` {value, prev, delta, pct, days, prev_days} and `line`. A sum adds days, a p50 or p90 is the median of daily values, a gauge is its last value, a ratio comes from the sums, cost is one read over the window. `delta` is null unless both weeks read the metric on as many days. `day_log_rollup.prom` (`agent_ci_*`, `agent_usage_*`, `agent_queue_*`, `agent_board_rows`, `agent_phases_ticked`, `agent_week_*`) carries the last finished day and the week.

ETA accuracy stays in fleet-bench; the record copies its headline.

The board is the hub's Today tab (Prefix O, `hub:board`): every section in full, scrolled with j/k, space, g/G, `n`/`N` jumping between sections, `[`/`]` stepping days; the History tab (7) lists every recorded day. `hub --once --tab today` prints it as text. `day-log show` prints the same record as markdown.

## Do NOT

- Do not call `gh` yourself to count the day. Two producers drift; a scope or bound fix belongs in `day-log`, and grouping belongs in `~/.config/day-log/groups`.
- Do not read `usage` cost as the day's spend. It is the whole-session spend of every session active that day, so a session that ran for three days counts in full on each. The same goes for `agents.cost_usd`: for a week use `day-log week`.
- Do not recompute scorecard numbers. `bench` is `fleet-bench`'s own output, copied.
