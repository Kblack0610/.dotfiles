---
name: notes-system
description: User's notes toolchain rooted at ~/.notes, driven by the profile-aware `notes` Rust CLI. Use when creating or reading daily journal entries, managing backlogs/zettels, bootstrapping notes on a new machine, syncing notes to git, diagnosing notes issues, or answering questions about the notes layout. Do NOT hand-write markdown into ~/.notes/journal/ — use the CLI.
---

# notes-system

## Persona

- **Name:** Scribe
- **Icon:** 🪶
- **Title:** The Chronicler
- **Role:** Owns "what got written down" — the notes vault, daily summaries, wind-down
  narratives, briefs, and the lab status feed
- **Style:** Faithful, concise, structured; records rather than embellishes
- **Autonomy rung:** draft / author (never edits auth/runtime state; uses the `notes` CLI, never
  hand-writes the journal)
- **Carrying primitive:** skill voice — home here; also voices `daily:summary`, `wind-down`,
  `one-pager`, `lab-sync`
- **Notify channel:** the notes vault + generated summaries
- **Registry:** `~/.dotfiles/.claude/PERSONAS.md`

The user maintains a git-backed notes repo at `~/.notes`. All **journal logic** goes through the
`notes` Rust CLI (source `~/.dotfiles/.local/src/notes-cli/`, binary at `~/.local/bin/notes`);
the **sync layer** is separate shell + systemd/launchd. Drive everything through these tools;
do not reinvent their logic.

## Layout

```
~/.notes/
├── inbox/            # dated human/agent captures only (`notes inbox`); _archive/ holds drained items
├── journal/
│   ├── daily/        # YYYY-MM-DD.md files (`notes today` target)
│   ├── backlogs/     # standing fun.md + carryover.md (linked from daily footer)
│   ├── refs/         # per-day reference material, auto-linked into daily ## Refs
│   ├── permanent/    # zettelkasten atomic notes (`notes zettel new`)
│   ├── index/        # generated backlinks + MOC (`notes index --rebuild`)
│   ├── summaries/    # continuous/ (rolling monthly) + monthly/ rollups
│   └── daily_archive/# archived dailies (YYYY/YYYY-MM/)
├── knowledge/        # long-form notes
├── employment/       # job/company notes (corporate profile roots here)
└── _archive/         # incl. retired Obsidian setup (_archive/obsidian/)
```

Notes repo has two git remotes: `origin` (Forgejo at `git.example.internal/kblack0610/.notes`) and `backup` (GitHub `Kblack0610/.notes`, push-only from the master device `cachyos-x8664-main`).

Sync is event-driven by a Forgejo push webhook → in-cluster `notes-sync-bridge` → mosquitto + ntfy fan-out, with a 5-min fallback timer per platform:

| Platform | Push side | Pull side | Fallback |
|---|---|---|---|
| Linux | `notes-watch.service` (inotifywait + 3s debounce) | `notes-mqtt.service` (mosquitto_sub) | `git-sync-notes.timer` 5min |
| macOS | `com.kblack.notes-watch.plist` (launchd `WatchPaths`) | `com.kblack.notes-mqtt.plist` | `com.kblack.git-sync-notes.plist` 5min |
| Windows | `notes-watch` Scheduled Task (FileSystemWatcher) | `notes-mqtt` Scheduled Task (mosquitto_sub.exe) | `notes-sync-fallback` Scheduled Task 5min |
| Termux | `~/.termux/boot/notes-watch.sh` (inotifywait) | ntfy Android app (FCM-backed) | crond 5min |

## Profiles

`~/.config/notes/config.toml` is the single source of truth for paths. Profile resolution:
`--profile` flag → `$NOTES_PROFILE` → `[hostname_map]` (by `hostname -s`) → `default_profile`.

- `personal` (default): journal under `~/.notes/journal/`
- `AcmeCorp`: daily notes + refs rooted at `~/.notes/employment/jobs/AcmeCorp/`
  (corporate machines). Same git repo — only the active location changes.

`notes config` prints the resolved profile + every path; use it before assuming any location.

## The `notes` CLI

| Command | What it does |
|---|---|
| `notes today` | Idempotent daily note. Carries **Priority** forward (day-stamped `(Nd) <!-- since:DATE -->`); rolls unfinished **Focus** into the carryover backlog; drops checked/empty items; links refs; appends the backlog footer. The `today` alias runs this + opens nvim. |
| `notes path` | Print today's note path (profile-aware). |
| `notes link-refs` | Link `refs/<date>/*.md` into today's `## Refs` (idempotent). |
| `notes summarize [--date D] [--force]` | Append a day's summary to `summaries/continuous/YYYY-MM.md`. **Dedup-safe** (skips dates already logged); WARNs on missing notes instead of failing silently. Runs nightly at 01:00 (`journal-daily-summarize.timer`). |
| `notes archive [--month M] [--dry-run] [--backfill]` | Roll a month into `summaries/monthly/` + move dailies to `daily_archive/`. Runs on the 2nd at 01:30 (`journal-monthly-archive.timer`). |
| `notes inbox` | Triage view of the dated-capture inbox (`inbox/<date>.md`, `<date>-analysis.md`): pending captures oldest-first with age + title, stale (≥14d) flagged. No subcommand = `list`. |
| `notes inbox add "<text>"` | Quick-capture from the terminal — append a timestamped bullet to today's `inbox/<date>.md` (creates it with a header if new). |
| `notes inbox archive <file> \| --stale \| --before D` | Drain triaged captures into `inbox/_archive/` so the active view only shows what still needs processing. Pick exactly one selector. |
| `notes backlog <fun\|carryover>` | Tidy a backlog (sweep `- [x]` → `## Done`, restamp day counts), print its path. Aliases: `fun`, `co`. |
| `notes seed-backlogs [--from N] [--force]` | One-time migration of inline `## Fun`/`## Carry Over` sections into the backlog files. |
| `notes zettel new "<title>"` | Create `permanent/<YYYYMMDDThhmm>-<slug>.md` with frontmatter. Alias: `zk`. |
| `notes index [--rebuild]` | Scan `[[wikilinks]]`; report or regenerate `index/backlinks.md` + `index/moc.md`. |
| `notes doctor` | Diagnose: profile/dirs, **summarize gaps**, heading validity, sync freshness, service status, dead links/orphans. Alias: `ndoctor`. **Run this first when "notes are broken".** |

Structured log: `~/.local/state/notes/journal.log`; `--verbose` echoes to stderr.
Daily-note model: only fresh **Focus** + **Priority** inline; Fun/Carry Over live in
`journal/backlogs/` (footer-linked); no separate done-log (history = git + `daily_archive/`).
Wikilinks resolve in nvim via a vanilla-`gf` autocmd (path + suffixesadd) — no plugin.

## Other scripts

### `notes-bootstrap`

One-time setup on a new machine. Links sync scripts + `~/.config/notes`, **builds the `notes`
binary** (`cargo build --release`; warns if cargo missing — shell falls back to the deprecated
`journal-create`), registers timers/services per platform (incl. `journal-daily-summarize` and
`journal-monthly-archive` on Linux), clones the repo, configures remotes.

```bash
notes-bootstrap --primary-url https://git.example.internal/kblack0610/.notes.git
# or env vars:
NOTES_PRIMARY_REMOTE_URL=... NOTES_BACKUP_REMOTE_URL=... notes-bootstrap
```

Flags: `--force` (overwrite existing files), `--primary-url`, `--backup-url`. Auto-detects Termux vs macOS vs desktop Linux. On Windows, the equivalent is `~/.dotfiles/.local/src/installation_scripts/windows/setup_notes_sync.ps1` (registers Scheduled Tasks). Idempotent.

### `notes-sync`

Thin wrapper that `exec`s `~/.local/src/git/git-sync-notes.sh`. Pulls from origin, commits local changes, pushes to both remotes. Called on a timer — rarely needs to be invoked manually, but safe to run anytime.

### `notes-termux-bootstrap`

Android-specific variant of `notes-bootstrap`. Use on Termux when the auto-detection needs an override.

### `notes-to-vikunja`

Bridge that captures **project tasks** from today's daily note into Vikunja (`vikunja.example.internal`). One-directional: notes are the capture surface, Vikunja stays the source of truth. Script: `~/.local/src/notes-vikunja/notes-to-vikunja` (Python stdlib); runs every 15 min via `notes-vikunja.timer`, or manually (`--dry-run`, `--date YYYY-MM-DD`).

What syncs (everything else stays notes-only):

| Line in daily note | Lands in |
|---|---|
| `- [ ] myapp: fix bug waves` | Vikunja project `myapp` (prefix must match an existing project title or a `PROJECT_ALIASES` alias) |
| `- [ ] fix bug waves #dodginballs` | Vikunja project `dodginballs` |
| `- [ ] renew passport @vk` | Vikunja `Inbox` project (opt-in capture for non-project tasks) |

Mechanics:
- Captured tasks get the `from-notes` label; `<!-- since: -->` dates land in the description.
- Dedup state: `~/.local/state/notes-vikunja/synced.tsv`, keyed on the notes CLI's `task_key` normalisation — carry-forward `(Nd)` re-stamping never duplicates. **No write-back into the note** (stamp_line would clobber it).
- Checking a previously synced task (`- [x]`) marks it done in Vikunja on the next run.
- Unknown project names are skipped, never auto-created.
- Config/token: `~/.config/notes-vikunja.env` (machine-local; `VIKUNJA_API_TOKEN`, falls back to `$VIKUNJA_MCP_TOKEN` for manual shell runs).

### `journal-create` (deprecated)

Legacy bash creator of daily notes — superseded by `notes today`. Kept only as the shell
fallback for machines without cargo. It still emits the OLD inline Fun/Carry Over format and is
not profile-aware; never prefer it when the binary exists.

## Rules

- **Never hand-author a daily note file.** Run `notes today` (Rust CLI, profile-aware) — it handles carry-forward, day-tracking stamps, refs linking, and backlog footers that a manual write would silently break. (`journal-create` is the deprecated bash fallback.)
- **Never edit the `<!-- since:YYYY-MM-DD -->` HTML comments** on carried items — the tool uses them to recompute the `(Nd)` suffix each day.
- For reading notes, it's fine to `cat` / grep / read files directly — they're plain markdown.
- The user uses **shell + neovim** for notes editing, **never Obsidian**. All Obsidian traces were removed 2026-06-04; the old setup is archived at `~/.notes/_archive/obsidian/` (see its README). Do not reintroduce Obsidian config or plugins.
- When adding a new daily task mid-day, edit today's note directly; `notes today` is idempotent (one note per day).
- Completed backlog items belong in that backlog's `## Done` section (`notes backlog` sweeps them) — don't delete them.
- **The inbox is for dated human/agent captures only** (`inbox/<date>.md`, `<date>-analysis.md`). Telemetry, monitoring snapshots, and agent activity logs are runtime state → they belong under `~/.agent/` or `~/.local/state/` (the runtime axis), **never** the `~/.notes` vault. Triage with `notes inbox`; drain processed items with `notes inbox archive`.

## Related

- CLI source + full docs: `~/.dotfiles/.local/src/notes-cli/README.md`.
- Profile config: `~/.config/notes/config.toml` (→ `~/.dotfiles/.config/notes/config.toml`).
- Memory index: `~/.claude/projects/-home-kblack0610--dotfiles/memory/user_notes_system.md` (may or may not exist — the MEMORY.md index references it).
- Systemd units: `~/.config/systemd/user/git-sync-notes.{service,timer}`, `journal-daily-summarize.{service,timer}`, `journal-monthly-archive.{service,timer}`, `journal-refs-archive.{service,timer}`, `notes-vikunja.{service,timer}`.
- Core sync logic: `~/.local/src/git/git-sync-notes.sh` (runbook: `~/.local/src/git/NOTES_SYNC_SETUP.md`).
