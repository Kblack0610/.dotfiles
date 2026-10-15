# notes

A single, profile-aware binary that owns all **journal + zettelkasten** logic for
the `~/.notes` vault. The git/MQTT **sync layer is separate** (shell + systemd/
launchd) and untouched — this tool only reads and writes note files.

Everything is pure Rust (chrono for dates), so behaviour is identical on macOS and
Linux: no GNU-vs-BSD `date`/`sed`/`stat` divergence, no Python-on-Mac drift.

## Why it exists

The old journal logic was split across `journal-create` (bash), two Python scripts,
and shell aliases — each with its **own hardcoded path**, so per-machine roots were
impossible and failures (a missing note, a mistyped heading) were silent. This binary
unifies all of it behind one config and adds a `doctor` command so problems are
visible instead of mysterious.

## Install

```sh
cargo build --release
ln -sf ../../.dotfiles/.local/src/notes-cli/target/release/notes ~/.local/bin/notes
```

`notes-bootstrap` does both automatically (and on every machine).

## Configuration

`~/.config/notes/config.toml` (symlinked from `~/.dotfiles/.config/notes/`). The
binary also falls back to `$NOTES_CONFIG` and `~/.dotfiles/.config/notes/config.toml`,
and to a built-in `personal` default if none exist.

Active profile resolves: `--profile` → `$NOTES_PROFILE` → `[hostname_map]` (by
`hostname -s`) → `default_profile`. This is what lets a corporate machine root its
daily notes inside `employment/jobs/<job>/` while a personal machine uses
`journal/daily` — same git repo, different active location.

**A job is one line.** Every path key defaults to the org convention (`daily/`, `refs/`,
`backlogs/fun.md`, `summaries/`, `daily_archive/`, `permanent/`, `meetings/`, `index/`,
`knowledge/`, `inbox/`, `projects/current`), so a new org is just its `root` plus whatever genuinely
differs. `personal` is the sole profile that overrides them all, because its root IS the
vault. An org that still holds a `log/` from before the directory was renamed is migrated
to `daily/` on the next `notes today`; a profile that explicitly pins `daily = "log"`
keeps it.

## Commands

| Command | What it does |
|---|---|
| `notes today` | Idempotent daily note. Carries unfinished **Focus** forward (day-stamped), surfaces anything the schedule fires, adds `## Projects`, links refs, regenerates the footer, publishes the status pages, and conforms a note an older build left behind. |
| `notes path` | Print today's note path (for `nvim "$(notes path)"`). |
| `notes link-refs` | Link today's `refs/<date>/*.md` into the note's `## Refs`. |
| `notes summarize [--date D] [--force]` | Append a day's summary to the continuous monthly log. **Dedup-safe**; WARNs on gaps/empty extraction. |
| `notes archive [--month M] [--dry-run] [--backfill]` | Roll a month into the monthly summary + move dailies to the archive tree. |
| `notes backlog <fun\|scheduled\|recurring>` | Open a standing backlog and print its path. `fun`/`scheduled` are tidied (sweep checked → `## Done`, restamp day counts); `recurring` is only ensured (never swept — its masters aren't checked off). |
| `notes focus [list]` | List today's open `## Focus` items — the daily cockpit's active-task list. Same items the session-start hook surfaces at turn 1. |
| `notes focus add "<text>"` | Append a new open task under today's `## Focus`, freshly day-stamped. Bootstraps today's note if absent. Keep it a couple words. |
| `notes focus done <word>` | Check off the first open `## Focus` item whose text matches `<word>` (case-insensitive). |
| `notes focus --all` | Cross-profile cockpit: aggregate every configured profile's open `## Focus` items as TSV `profile<TAB>file<TAB>line<TAB>key<TAB>text` (for editor/jump integration). Close a row with `notes --profile <p> focus done "<key>"`. |
| `notes inbox [list]` | Triage view of the dated-capture inbox — pending captures oldest-first with age + title, stale (≥14d) flagged. |
| `notes inbox add "<text>"` | Quick-capture: append a timestamped bullet to today's `inbox/<date>.md`. |
| `notes inbox archive <file>\|--stale\|--before D` | Drain triaged captures into `inbox/_archive/` (pick one selector). |
| `notes seed-backlogs [--from N] [--force]` | One-time migration: lift `## Fun` + `## Carry Over` out of a daily note into the backlog files. |
| `notes zettel new "<title>"` | Create `permanent/<id>-<slug>.md` (id = `YYYYMMDDThhmm`). |
| `notes index [--rebuild]` | Scan `[[wikilinks]]` across `permanent/` and `knowledge/`; report or rebuild `index/` backlinks + MOC (zettels by tag, then `## Knowledge` by subdir, each article with its title, summary and tags; `knowledge/_log/` is skipped). |
| `notes knowledge init [--force]` | Write `knowledge/SCHEMA.md`, the article contract (frontmatter, sections, links, tag vocabulary), from the template built into the binary (`src/knowledge_schema.md`). |
| `notes knowledge due [-n N]` | The N articles most due for a whole-article review, oldest `reviewed` first. |
| `notes knowledge apply <ops.json> [--started <unix>] [--dry-run]` | The only writer for the nightly knowledge engine: validates a batch of create/update ops (path under `knowledge/`, required frontmatter, shrink guard, loses to a human edit made after `--started`), snapshots a hand-written article to `_log/originals/` the first time it is rewritten, and writes the date's immutable log `knowledge/_log/YYYY/MM/YYYY-MM-DD.md`. The log is also the checkpoint: a date applies once. |
| `notes doctor` | Diagnose: config/profile, dirs, **summarize gaps**, heading validity, sync freshness, service status, dead links/orphans, and whether the **binary is stale** against its own source. |
| `notes config` | Print the resolved profile + all paths. |

`--verbose` echoes the structured log (also written to `~/.local/state/notes/journal.log`).

## Daily-note model

Lean by design: **ONE** task list, `## Focus`, swept into `### Urgent` / `### High` /
`### Low` / `### Done` lanes. There is no second inline list. `## Due` (and its `## Priority`
ancestor) was removed because two lists in one note make every glance a merge, and anything a
schedule surfaces IS today's work; a note left over from an older build has its Due items
folded into Focus on the next run. **Fun** is a standing backlog file linked in the footer.
Completed items move to a `## Done` section in the same file (history via git +
`daily_archive/`), so there's no separate done log.

**Time-triggered tasks** all live in one `schedule.md` (its `scheduled.md` + `recurring.md`
ancestors were merged and renamed aside). What a line does is decided by its TOKEN, not by
which file it sits in: `[YYYY-MM-DD]` fires ONCE within the lead window and the master line is
consumed; `(every:…)` fires each matching day and the master is kept, so the habit returns
every cycle and missed days are simply skipped. Cadences: `every:fri`, comma lists
`every:mon,thu`, `every:weekday` (Mon-Fri), `every:day`, and day-of-month `every:1st` /
`every:15th` / `every:last`. Tagging a surfaced task with a far-future date pushes it back out
to the schedule, which is what makes the date a two-way verb.

Which backlogs the footer links is config-driven via `footer_links` (names: `backlog`/`fun` |
`schedule`, or a vault-relative path; default `["backlog", "schedule"]`) - edit that list in
`config.toml`, no recompile. `footer_backlogs` is the old key name, still read as an alias.

**The note is written once a day.** `notes today` builds the note when it creates it, and after that only you write to it. Everything that changes during the day lives on a status page beside the note under `<root>/status/`, reached from the footer:

- `status/watches.md` - Sentinel watches (set `watches = "~/.agent/watches"`; state read from `~/.local/state/watch-companion/<name>.state`). Read-only against the Sentinel runtime.
- `status/comms.md` - the mail triage poller's surface file plus its stats line. Skipped on a machine without comms config, so it never overwrites the page another machine publishes.
- `status/inbox.md` - today's quick-captures (`inbox/<today>.md`), with a short `(sess <8-char>)` suffix when `notes inbox add` ran inside a Claude Code session, so a capture links back via `claude -r <id>`.

A note written by an older build has its `## Watches`, `## Comms`, `## Inbox` and `## Work` sections removed once each page is on disk.

**Projects** - the note's one generated section, rendered at creation: quick links to every project tagged `#beta` or `#alpha` (see `notes projects --stage`) in this org and in each org listed in `rollup`, one small `### <org>` block per org that has any. Prod and draft projects are left out. Links are vault-relative, so they resolve from any org.

**Morning** - at the top, above Notes, re-rendered only when it changes: the morning briefing (`journal/refs/<date>/briefing.md`, its headline and "Needs you" items; it is not repeated under Refs) and every knowledge-engine log from the last week that the previous note did not already list, with the articles it created or updated. With nothing new it names the last compile date, so a stalled engine shows.

**Footer** - one `- Label: [[target]]` per line below a `---`: the `footer_links` files, the project board and agent board, this org's project index, the knowledge MOC, and the three status pages. It carries no counts, so it only changes when the set of links does.

## Wiring

- Aliases (`.commonrc`): `today`, `fun`, `co`, `zk`, `ndoctor` → the binary.
- Timers: `journal-daily-summarize.service` → `notes summarize`,
  `journal-monthly-archive.service` → `notes archive`.
- Legacy `journal-create` + the two Python scripts are deprecated fallbacks.

## Tests

`cargo test` — covers the historically fragile bits: date/day-count stamping,
carry-forward filtering, section extraction, profile + hostname resolution,
backlog sweep, link extraction.
