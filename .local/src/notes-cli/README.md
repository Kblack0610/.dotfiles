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

## Commands

| Command | What it does |
|---|---|
| `notes today` | Idempotent daily note. Carries **Priority** forward (day-stamped); rolls unfinished **Focus** into the carryover backlog; links refs; footer links to backlogs. |
| `notes path` | Print today's note path (for `nvim "$(notes path)"`). |
| `notes link-refs` | Link today's `refs/<date>/*.md` into the note's `## Refs`. |
| `notes summarize [--date D] [--force]` | Append a day's summary to the continuous monthly log. **Dedup-safe**; WARNs on gaps/empty extraction. |
| `notes archive [--month M] [--dry-run] [--backfill]` | Roll a month into the monthly summary + move dailies to the archive tree. |
| `notes backlog <fun\|scheduled\|recurring>` | Open a standing backlog and print its path. `fun`/`scheduled` are tidied (sweep checked → `## Done`, restamp day counts); `recurring` is only ensured (never swept — its masters aren't checked off). |
| `notes inbox [list]` | Triage view of the dated-capture inbox — pending captures oldest-first with age + title, stale (≥14d) flagged. |
| `notes inbox add "<text>"` | Quick-capture: append a timestamped bullet to today's `inbox/<date>.md`. |
| `notes inbox archive <file>\|--stale\|--before D` | Drain triaged captures into `inbox/_archive/` (pick one selector). |
| `notes seed-backlogs [--from N] [--force]` | One-time migration: lift `## Fun` + `## Carry Over` out of a daily note into the backlog files. |
| `notes zettel new "<title>"` | Create `permanent/<id>-<slug>.md` (id = `YYYYMMDDThhmm`). |
| `notes index [--rebuild]` | Scan `[[wikilinks]]`; report or rebuild `index/` backlinks + MOC. |
| `notes doctor` | Diagnose: config/profile, dirs, **summarize gaps**, heading validity, sync freshness, service status, dead links/orphans. |
| `notes config` | Print the resolved profile + all paths. |

`--verbose` echoes the structured log (also written to `~/.local/state/notes/journal.log`).

## Daily-note model

Lean by design — only fresh **Focus** + **Priority** live inline. **Fun** and
**Carry Over** are standing backlog files (`journal/backlogs/`) linked at the bottom.
Completed backlog items move to a `## Done` section in the same file (history via git +
`daily_archive/`), so there's no separate done log.

**Recurring tasks** live in `journal/backlogs/recurring.md`. A master line carries an
`(every:…)` cadence token; on each matching day `notes today` emits a fresh unchecked
copy into the note's **Due** (token stripped, `since:` stamped, deduped). The master is
never consumed, so the habit returns every cycle — and missed days are simply skipped
(no stale pile-up). Cadences: `every:fri`, comma lists `every:mon,thu`, `every:weekday`
(Mon–Fri), `every:day`, and day-of-month `every:1st` / `every:15th` / `every:last`.
Contrast **scheduled** (`journal/backlogs/scheduled.md`), which is one-shot future
`[dates]`. Both `scheduled` and `recurring` resolve via a built-in path fallback, so no
`config.toml` change is needed.

Which backlogs the footer links is config-driven via `footer_backlogs` (names: `fun` |
`scheduled` | `recurring`, or a vault-relative path; default `["fun", "scheduled"]`) —
edit that list in `config.toml`, no recompile.

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

## Wiring

- Aliases (`.commonrc`): `today`, `fun`, `co`, `zk`, `ndoctor` → the binary.
- Timers: `journal-daily-summarize.service` → `notes summarize`,
  `journal-monthly-archive.service` → `notes archive`.
- Legacy `journal-create` + the two Python scripts are deprecated fallbacks.

## Tests

`cargo test` — covers the historically fragile bits: date/day-count stamping,
carry-forward filtering, section extraction, profile + hostname resolution,
backlog sweep, link extraction.
