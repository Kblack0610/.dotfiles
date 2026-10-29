---
name: day-log
description: >-
  What a day shipped, from the day-log record: every PR merged in any repo grouped by area and scope, the session that landed each one, what is still open, what waits on the human (MAIN reds, NEEDS sessions, pending asks), the fleet-bench scorecard, and spend. One JSON record per local day under ~/.agent/daylog, gathered by `day-log` with no model; the hub:log board (Prefix O) shows the same data. Use when the user asks "what got done today", "what did we ship yesterday", "summary of the day", "what merged this week", "show me the day log", "which session landed #N", or wants the day as a shareable page. Not for live session state (fleet-sessions watch, fleet-overseer status), not for ETAs or the scorecard's method (fleet-bench), and not for one session's history after it ended (session-outcomes).
metadata:
  category: monitoring
  tags: [fleet, prs, daily, history, observability]
  reviewed: "2026-10-28"
---

# day-log

Answers "what did the day produce" from one record per day, so a chat answer, the `hub:log` board, the notes ref and an Artifact page all say the same thing. The producer is `day-log` (`~/.local/bin/day-log`); this skill only reads it.

## When to Use

- The user asks what got done, merged or shipped today, yesterday, or on a given date.
- The user asks for the week: read each day's record and add them up.
- The user wants the day as a page to look at or share.

Not for what sessions are doing right now (`fleet-overseer status`, the `hub:watch` board) and not for how the scorecard is computed (`fleet-bench`).

## Steps

1. Read the record. `day-log json` gathers today fresh (about 5 s, three gh searches). `day-log json --date YYYY-MM-DD` reads a past day; if it says `no record`, run `day-log snapshot --date YYYY-MM-DD` to gather it (merged PRs and spend come back; the live sections stay empty for a day nobody watched).
2. Check `.unreadable` first. A name there (`gh merged`, `gh open`, `fleet state`) means that part is the last good copy, not current; say so.
3. Answer in prose, summary before detail: merged count and repos, then each area and group with its notable PRs, then what is open, then what waits on the human, then the scorecard headline (`.bench.headline`, quote it as is). Name the session that landed a PR from `.by` only when it is set.
4. For a page, publish an Artifact built from the same JSON (one section per area, every PR linked), so it cannot disagree with the board.

Record fields: `merged[]` (repo, number, title, url, merged_at, scope, group, area, by), `open[]` (repo, number, title, created_at, updated_at, draft, ci, by), `waiting` (main, needs, asks), `fleet` (sessions, buckets, holds, unity_runs), `bench` (headline, sessions), `usage[]` (project, sessions, tokens, cost_usd), `timeline[]`, `unreadable[]`, `live`.

The board (`day-log watch`, hub:log, Prefix O) folds each section to fit the pane. When the user wants a full list there, point them at the keys rather than dumping it: `1`-`5` or a click on a section header opens that section in full and folds the others (again or Esc closes it), and j/k, space/b, g/G or the mouse wheel scroll it. `day-log watch --once --open merged` prints the same view.

## Do NOT

- Do not call `gh` yourself to count the day. Two producers drift; a scope or bound fix belongs in `day-log`, and grouping belongs in `~/.config/day-log/groups`.
- Do not read `usage` cost as the day's spend. It is the whole-session spend of every session active that day, so a session that ran for three days counts in full on each.
- Do not recompute scorecard numbers. `bench` is `fleet-bench`'s own output, copied.
