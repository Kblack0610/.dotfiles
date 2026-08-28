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
`inbox/`, `projects/current`), so a new org is just its `root` plus whatever genuinely
differs. `personal` is the sole profile that overrides them all, because its root IS the
vault. An org that still holds a `log/` from before the directory was renamed is migrated
to `daily/` on the next `notes today`; a profile that explicitly pins `daily = "log"`
keeps it.

## Commands

| Command | What it does |
|---|---|
| `notes today` | Idempotent daily note. Carries unfinished **Focus** forward (day-stamped), surfaces anything the schedule fires, links refs, regenerates the footer, and conforms a note an older build left behind. |
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
| `notes index [--rebuild]` | Scan `[[wikilinks]]`; report or rebuild `index/` backlinks + MOC. |
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

**Inbox** is surfaced two ways: a footer `Inbox (N): [[inbox]]` link when there are
pending captures (N = capture files awaiting triage, same count as `notes inbox`), and a
`## Inbox` section near the bottom of the note listing **today's** quick-captures inline
(the bullets in `inbox/<today>.md`) as checkbox tasks, refreshed every `notes today` so
captures added during the day show up. Ticking one off is preserved across refreshes.
The section self-hides on days with no captures.

**Session tagging** — when `notes inbox add` runs inside a Claude Code session it stamps
the capture with `<!-- session:<id> -->` (from `$CLAUDE_CODE_SESSION_ID`). The `## Inbox`
section then shows a short `(sess <8-char>)` suffix, so a capture links back to the
conversation that produced it via `claude -r <id>`. Plain terminal captures are untagged.

**Sentinel watches** — set `watches = "~/.agent/watches"` in `config.toml` (opt-in;
default off) and `notes today` renders a `## Watches` section listing each registered
watch with its live state (`OK` / `TRIP` / `ERROR` / `paused`), unhealthy first,
refreshed every run. State is read from `~/.local/state/watch-companion/<name>.state`
(override the dir with `watches_state`). These are runtime paths outside the vault; the
notes CLI only reads them (it never writes to the Sentinel runtime, and Sentinel never
writes to the vault).

**Work roster** - set `rollup = ["acmecorp", "othercorp"]` on a profile (opt-in; default
off) and `notes today` renders a `## Work` section: one collapsed line per job with a link
to that job's latest note and its open-task count, e.g. `- acmecorp - [[..]] (7 open)`.
It is its own H2 section (kept above the footer like `## Watches`), regenerated every run,
so it is never carried forward into tomorrow's note nor folded into summaries. The tasks
themselves stay in the job's own note - the point is a glance-value pointer, not a copy;
`gf` on the link jumps you into the job note where you read and complete them. Every
configured job is listed even at zero open (a stable roster); a job with no note yet is
listed link-less as `(no note yet)`.

`## Work` is separate from `## Focus` by design: Focus is your personal now, Work is the
per-job pointer. (An earlier design mirrored each job's tasks inline under Focus behind a
`<!-- rollup:start -->` sentinel; `refresh_work` still strips any such legacy block from an
existing note - surgically, preserving any tasks the user interleaved with it - so notes
upgrade in place.)

Two properties worth knowing:

- No-op when `rollup` is empty. The config is machine-local and gitignored, so a machine
  without the key must not add a `## Work` section the next 5-minute sync would strip off
  the machine that has it - the same ping-pong guard `## Watches` uses.
- The count regenerates from the job note each run, so it tracks reality as you complete
  tasks there; byte-stable between runs when nothing changed (no cross-machine churn).

## Wiring

- Aliases (`.commonrc`): `today`, `fun`, `co`, `zk`, `ndoctor` → the binary.
- Timers: `journal-daily-summarize.service` → `notes summarize`,
  `journal-monthly-archive.service` → `notes archive`.
- Legacy `journal-create` + the two Python scripts are deprecated fallbacks.

## Tests

`cargo test` — covers the historically fragile bits: date/day-count stamping,
carry-forward filtering, section extraction, profile + hostname resolution,
backlog sweep, link extraction.
