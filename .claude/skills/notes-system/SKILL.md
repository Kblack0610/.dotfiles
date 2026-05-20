---
name: notes-system
description: User's shell-based notes toolchain rooted at ~/.notes. Use when creating or reading daily journal entries, bootstrapping notes on a new machine, syncing notes to git, or answering questions about the notes layout. Do NOT hand-write markdown into ~/.notes/journal/ — use the scripts.
---

# notes-system

The user maintains a git-backed notes repo at `~/.notes` with a set of shell scripts in `~/.dotfiles/.local/bin/`. Drive everything through those scripts; do not reinvent their logic.

## Layout

```
~/.notes/
├── inbox/            # quick capture
├── journal/
│   ├── daily/        # YYYY-MM-DD.md files (journal-create target)
│   └── refs/         # per-day reference material, archived by a systemd timer
├── knowledge/        # long-form notes
└── dev/projects/<name>/summary.md   # auto-linked from daily notes
```

Notes repo has two git remotes: `origin` (Forgejo at `git.kblab.me/kblack0610/.notes`) and `backup` (GitHub `Kblack0610/.notes`, push-only from the master device `cachyos-x8664-main`).

Sync is event-driven by a Forgejo push webhook → in-cluster `notes-sync-bridge` → mosquitto + ntfy fan-out, with a 5-min fallback timer per platform:

| Platform | Push side | Pull side | Fallback |
|---|---|---|---|
| Linux | `notes-watch.service` (inotifywait + 3s debounce) | `notes-mqtt.service` (mosquitto_sub) | `git-sync-notes.timer` 5min |
| macOS | `com.kblack.notes-watch.plist` (launchd `WatchPaths`) | `com.kblack.notes-mqtt.plist` | `com.kblack.git-sync-notes.plist` 5min |
| Windows | `notes-watch` Scheduled Task (FileSystemWatcher) | `notes-mqtt` Scheduled Task (mosquitto_sub.exe) | `notes-sync-fallback` Scheduled Task 5min |
| Termux | `~/.termux/boot/notes-watch.sh` (inotifywait) | ntfy Android app (FCM-backed) | crond 5min |

## Scripts

### `journal-create`

Creates today's daily note at `~/.notes/journal/daily/$(date +%Y-%m-%d).md`. **Idempotent** — exits cleanly if today's note already exists.

Carry-forward behavior (reads the most recent previous daily note):
- `## Priority` items — carried, with `(Nd)` day-tracking suffix since origin date
- `## Fun` items — carried, same day-tracking
- `## Focus` + previous `## Carry Over` — merged into today's `## Carry Over`
- Checked (`- [x]`) items are dropped
- Empty placeholder tasks (`- [ ]`) are dropped
- Auto-links active projects from `~/.lab/projects/current/*/` into `## Current Projects`

Usage: `journal-create` (no args). Reports carried sections to stdout.

### `notes-bootstrap`

One-time setup on a new machine. Installs symlinks for sync scripts, registers timers/services per platform, clones the notes repo, and configures remotes.

```bash
notes-bootstrap --primary-url https://git.kblab.me/kblack0610/.notes.git
# or env vars:
NOTES_PRIMARY_REMOTE_URL=... NOTES_BACKUP_REMOTE_URL=... notes-bootstrap
```

Flags: `--force` (overwrite existing files), `--primary-url`, `--backup-url`. Auto-detects Termux vs macOS vs desktop Linux. On Windows, the equivalent is `~/.dotfiles/.local/src/installation_scripts/windows/setup_notes_sync.ps1` (registers Scheduled Tasks). Idempotent.

### `notes-sync`

Thin wrapper that `exec`s `~/.local/src/git/git-sync-notes.sh`. Pulls from origin, commits local changes, pushes to both remotes. Called on a timer — rarely needs to be invoked manually, but safe to run anytime.

### `notes-termux-bootstrap`

Android-specific variant of `notes-bootstrap`. Use on Termux when the auto-detection needs an override.

## Rules

- **Never hand-author a daily note file.** Run `journal-create` instead — it handles carry-forward, day-tracking stamps, and project auto-linking that a manual write would silently break.
- **Never edit the `<!-- since:YYYY-MM-DD -->` HTML comments** on carried items — `journal-create` uses them to recompute the `(Nd)` suffix each day.
- For reading notes, it's fine to `cat` / grep / read files directly — they're plain markdown.
- The user uses **shell + neovim** for notes editing, not Obsidian (there is a stale `.obsidian/` dir; ignore it).
- When adding a new daily task mid-day, edit today's note directly; `journal-create` only runs once per day.

## Related

- Memory index: `~/.claude/projects/-home-kblack0610--dotfiles/memory/user_notes_system.md` (may or may not exist — the MEMORY.md index references it).
- Systemd units: `~/.config/systemd/user/git-sync-notes.{service,timer}`, `journal-refs-archive.{service,timer}`.
- Core sync logic: `~/.local/src/git/git-sync-notes.sh`.
