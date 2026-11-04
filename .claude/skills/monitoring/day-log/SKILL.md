---
name: day-log
description: >-
  What a day shipped: merged PRs by area, the session behind each, what waits on the human, spend. Use for "what got done today", "what merged this week", "which session landed #N". ETAs are fleet-bench.
metadata:
  category: monitoring
  tags: [fleet, prs, daily, history, observability]
  reviewed: "2026-11-03"
---

# day-log

Answers "what did the day produce" from one record per day, so a chat answer, the hub Today tab, the notes ref and an Artifact page all say the same thing. The producer is `day-log` (`~/.local/bin/day-log`); this skill only reads it.

## Scope and triggers

What a day shipped, from the day-log record: every PR merged in any repo grouped by area and scope, the session that landed each one, what is still open, what waits on the human (NIGHTLY reds, NEEDS sessions, pending asks), the fleet-bench scorecard, and spend. One JSON record per local day under ~/.agent/daylog, gathered by `day-log` with no model; the hub board's Today tab (Prefix O) shows the same data, and `day-log.timer` snapshots it every 5 minutes. Use when the user asks "what got done today", "what did we ship yesterday", "summary of the day", "what merged this week", "show me the day log", "which session landed #N", or wants the day as a shareable page. Not for live session state (the hub Sessions tab, shepherd status), not for ETAs or the scorecard's method (fleet-bench), and not for one session's history after it ended (session-outcomes).

## When to Use

- The user asks what got done, merged or shipped today, yesterday, or on a given date.
- The user asks for the week: read each day's record and add them up.
- The user wants the day as a page to look at or share.

Not for what sessions are doing right now (`shepherd status`, the hub Sessions tab) and not for how the scorecard is computed (`fleet-bench`).

## Steps

1. Read the record. `day-log json` gathers today fresh (about 5 s, three gh searches). `day-log json --date YYYY-MM-DD` reads a past day; if it says `no record`, run `day-log snapshot --date YYYY-MM-DD` to gather it (merged PRs and spend come back; the live sections stay empty for a day nobody watched).
2. Check `.unreadable` first. A name there (`gh merged`, `gh open`, `fleet state`) means that part is the last good copy, not current; say so.
3. Answer in prose, summary before detail: merged count and repos, then each area and group with its notable PRs, then what is open, then what waits on the human, then the scorecard headline (`.bench.headline`, quote it as is). Name the session that landed a PR from `.by` only when it is set.
4. For a page, publish an Artifact built from the same JSON (one section per area, every PR linked), so it cannot disagree with the board.

Record fields: `merged[]` (repo, number, title, url, merged_at, scope, group, area, by), `open[]` (repo, number, title, created_at, updated_at, draft, ci, by), `waiting` (main, needs, asks), `fleet` (sessions, buckets, holds, unity_runs), `bench` (headline, sessions), `usage[]` (project, sessions, tokens, cost_usd), `timeline[]`, `unreadable[]`, `live`.

The board is the hub's Today tab (Prefix O, `hub:board`): every section in full, scrolled with j/k, space, g/G, `n`/`N` jumping between sections, `[`/`]` stepping days; the History tab (7) lists every recorded day. `hub --once --tab today` prints it as text. `day-log show` prints the same record as markdown.

## Do NOT

- Do not call `gh` yourself to count the day. Two producers drift; a scope or bound fix belongs in `day-log`, and grouping belongs in `~/.config/day-log/groups`.
- Do not read `usage` cost as the day's spend. It is the whole-session spend of every session active that day, so a session that ran for three days counts in full on each.
- Do not recompute scorecard numbers. `bench` is `fleet-bench`'s own output, copied.
