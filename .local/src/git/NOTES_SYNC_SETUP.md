# Notes Sync Bootstrap

`~/.notes` is a git repo that stays in sync across every device — desktop
Linux, macOS, Windows, Android (Termux + ntfy app) — within a few seconds
typical, ≤5 min worst case.

## Architecture

```
   GitHub  (off-site backup, push only from master)
                ▲
                │
   ┌────────────┴───────────────┐
   │ cachyos-x8664-main         │   ◄── only device with `backup` remote
   │ (MASTER)                   │
   └──────────▲─────────────────┘
              │
   ┌──────────┴─────────────────────────────────────────┐
   │ Forgejo @ git.example.internal  (primary git, in-cluster)  │
   │ post-receive webhook ──┐                           │
   └────────────────────────┼───────────────────────────┘
                            ▼
              ┌──── notes-sync-bridge ────────────────┐
              │  HMAC-verifies, fans out to:          │
              │   • mosquitto: notes/sync/needed      │
              │   • ntfy:     notes-sync              │
              └────┬─────────────────────────┬────────┘
                   │                         │
        ┌──────────┴──┐                ┌─────┴─────┐
        │ mosquitto   │                │   ntfy    │
        └─────┬───────┘                └────┬──────┘
              │                              │
        Linux / macOS / Windows         Android (ntfy app)
        notes-mqtt subscriber           phone push channel
              │                              │
              ▼                              ▼
        notes-sync                      notes-sync (Termux)

   Every device also runs a 5-min fallback timer for resilience.
   Every notes-sync is store-sync --store notes (see "The sync engine").
```

## Required inputs

You provision two things outside git:

- An identity that can push to Forgejo (HTTPS token in `~/.git-credentials` is fine)
- The Forgejo URL: `https://git.example.internal/kblack0610/.notes.git`

The master device additionally has `backup` → `git@github.com:Kblack0610/.notes.git`. Other devices skip this.

## Desktop bootstrap (Linux + macOS)

On a new machine, the private overlay's `restore-private-state` clones `~/.notes` and runs this for you (installer README, "Private state"). By hand:

```bash
NOTES_PRIMARY_REMOTE_URL=https://git.example.internal/kblack0610/.notes.git \
~/.local/bin/notes-bootstrap
```

`notes-bootstrap` auto-detects Linux vs macOS and does the right thing:

- **Linux** — installs the systemd user units (`git-sync-notes.timer` 5-min fallback, `notes-watch` for inotify push, `notes-mqtt` + `notes-ntfy` for the pull subscribers).
- **macOS** — installs the launchd plists (`com.kblack.git-sync-notes`, `com.kblack.notes-watch` using `WatchPaths`, `com.kblack.notes-mqtt`) into `~/Library/LaunchAgents/`.

Two pull transports, one bridge fan-out: `notes-mqtt` subscribes to the LAN mosquitto broker (`notes/sync/needed`), `notes-ntfy` holds an HTTPS stream on the public ntfy topic (`notes-sync`). On-LAN devices get the lower-latency mosquitto path; off-LAN devices (e.g. a corp VDI that cannot resolve `mosquitto.example.internal`) fall through to `notes-ntfy` over the Cloudflare-fronted `ntfy.example.internal`, which is reachable anywhere. Both just trigger `notes-sync`, whose `flock` de-dupes overlapping runs, so running both is safe.

Required system packages (`packages.conf` covers them on a fresh install):

| Tool | Linux | macOS | Windows | Termux |
|---|---|---|---|---|
| git | yes | yes | yes | yes |
| inotify-tools | yes | — (launchd `WatchPaths` is native) | — (FileSystemWatcher) | yes |
| mosquitto-clients | yes | yes (`brew install mosquitto`) | `winget install Eclipse.Mosquitto` | yes |

`notes-watch.service` and `notes-mqtt.service` skip themselves via `ConditionFileIsExecutable` until their underlying binaries are installed; the 5-min fallback timer keeps things flowing in the meantime.

## Windows bootstrap

The full chain is `sync_dotfiles.ps1 → install_packages.ps1 → apply_configs.ps1`. The notes setup runs as part of `apply_configs.ps1`, gated on `$env:NOTES_PRIMARY_REMOTE_URL`:

```powershell
$env:NOTES_PRIMARY_REMOTE_URL = 'https://git.example.internal/kblack0610/.notes.git'
~\.dotfiles\.local\src\installation_scripts\windows\setup_notes_sync.ps1
```

Registers three Scheduled Tasks:

- `notes-sync-fallback` — every 5 minutes
- `notes-watch` — at logon, restart on failure (FileSystemWatcher with 3s debounce)
- `notes-mqtt` — at logon, restart on failure (`mosquitto_sub` subscriber)

Run a task manually: `Start-ScheduledTask -TaskName notes-sync-fallback`.

## Termux (Android) bootstrap

**Fast path (one command, no private repo, no Rust build).** Proved end to end on a Galaxy S21 (Android 15, Termux 0.119.0-beta.3, 2026-11-17). Steps, in order:

1. Install three apps from F-Droid: **Termux**, **Termux:Widget** (the home-screen icon) and **Termux:Boot** (sync after a reboot). Termux:Widget is its own add-on app. All three must come from F-Droid: Android only lets add-ons signed with the same key as Termux talk to it, so a Play Store or GitHub Termux will not work with F-Droid add-ons.
2. Open **Termux:Boot** once, so Android lets it run at boot.
3. Make a Forgejo access token with the `write:repository` scope (Settings -> Applications -> Generate new token).
4. In Termux, run:

   ```bash
   pkg install -y git \
     && git clone --depth 1 https://github.com/Kblack0610/.dotfiles ~/.dotfiles \
     && ~/.dotfiles/.local/bin/notes-phone-setup
   ```

5. When Android opens **All files access**, turn on "Allow permission", go back to Termux and press Enter.
6. When Android opens **Display over other apps** (Samsung calls it **Appear on top** and shows the app list), turn on Termux, go back and press Enter.
7. Paste the notes URL (`https://git.example.internal/kblack0610/.notes.git`) and the token. The URL must be reachable from the phone: a LAN-only host works on the home Wi-Fi only, so use the public hostname if the phone should sync away from home.
8. Add the icon: long-press the home screen -> Widgets -> Termux:Widget -> "Termux shortcut" (1x1) -> Add -> pick `notes` -> Add.

Tap `notes`: it pulls, opens today's daily note in neovim inside the persistent `notes` tmux session, and on `:wq` commits, pushes and refreshes the `/sdcard/notes` mirror. Reopening reattaches where you left off. Without the Rust `notes` CLI the launcher falls back to `~/.notes/journal/daily/<date>.md`. Set `NOTES_REMOTE=` and `NOTES_TOKEN=` to skip the prompts.

What the setup installs: `git openssh neovim tmux cronie termux-services`; wrappers in `~/.local/bin` (`notes-mobile`, `notes-sync`, `notes-mirror-shared`) that run the dotfiles scripts with Termux's bash; `~/.shortcuts/notes`; an hourly crontab line (`0 * * * *` sync plus mirror) run by the `crond` termux-service; and `~/.termux/boot/notes-sync.sh`, which starts termux-services and syncs once, retrying while the network comes up. The hourly sync only runs while Termux is alive: opening the Termux app (or a reboot, through Termux:Boot) starts `crond` again after Android kills it.

| Symptom | Cause | Fix |
|---|---|---|
| No Termux:Widget in the widget list | It is its own F-Droid app; Termux does not include it | Install Termux:Widget from F-Droid |
| "Unsafe app blocked" by Play Protect, with only "Got it" | Play Protect flags F-Droid's Termux:Boot build (old target SDK) | Install it from the F-Droid app, or turn off Play Protect's app scan for that one install, then back on |
| Tapping the `notes` icon flashes a toast and nothing opens | Termux lacks "Display over other apps" | Settings -> Apps -> Termux -> Display over other apps (Samsung: Appear on top) -> on |
| Widget tap shows `notes-mobile: cannot execute: required file not found` | Shortcut pointed at a `#!/usr/bin/env bash` script, which only works where termux-exec is preloaded, and widget launches have none | Re-run `notes-phone-setup`, which installs wrappers that call Termux's bash |
| Storage step finishes but `/sdcard/notes` never appears | "All files access" was not turned on in time | Turn it on (Settings -> Apps -> Termux -> Files and media / All files access), then re-run the setup |
| No hourly sync; `sv status crond` says down | `sv-enable crond` failed because termux-services was not running in the setup shell | Re-run the setup; it removes `$PREFIX/var/service/crond/down` and starts runsvdir |
| Clone fails away from home | The URL is a LAN-only hostname; Tailscale does not route it | Use the public hostname for the notes remote |
| `pkg install failed` | No working Termux mirror | Run `termux-change-repo`, pick a mirror, re-run |

**Full path (builds the Rust CLI + all services).** Uses the private-overlay `notes-bootstrap`:

```bash
~/.dotfiles/.local/bin/notes-termux-bootstrap \
  --primary-url https://git.example.internal/kblack0610/.notes.git
```

Plus install the official **ntfy Android app** and subscribe to:

```
https://ntfy.example.internal/notes-sync
```

(A LAN-only `ntfy` host is reachable on the home Wi-Fi only; Tailscale does not route it, so away from home subscribe through a public hostname.)

The ntfy notifications use the OS push channel: near-zero battery cost. The Termux side keeps the hourly cron and the `~/.termux/boot/notes-sync.sh` hook as fallback.

### One-tap into today's note

`notes-termux-bootstrap` also installs `neovim`, `tmux`, and `rust` (to build the `notes` CLI) and writes a Termux:Widget shortcut at `~/.shortcuts/notes` that runs `notes-mobile`: pull, open today's daily note in neovim inside a persistent `notes` tmux session, push on exit. The tmux session means reopening the phone reattaches where you left off.

To get the home-screen icon: install **Termux:Widget** from F-Droid, then long-press the home screen -> Widgets -> Termux:Widget -> "Termux shortcut" -> pick `notes`. Tapping it lands you straight in today's daily note. `notes-mobile` also runs on desktop/macOS for testing.

### Glance widget: today's note on the home screen

Other apps cannot read `~/.notes` (Termux private storage), so `notes-mobile` and the phone's sync cron mirror today's note into shared storage via `notes-mirror-shared`:

- `/sdcard/notes/today.md`: the full note (for a content widget)
- `/sdcard/notes/tasks.txt`: checkbox lines as todo.txt (for a read-only task widget)

`notes-phone-setup` runs `termux-setup-storage` (Android's "All files access" page) and wires the mirror into boot + hourly sync. Then:

- **Task list (recommended, least fuss):** install **Simpletask** (FOSS) pointed at `/sdcard/notes/tasks.txt`. Renders a clean checklist widget, no formulas. Read-only for now (checking off does not sync back yet).
- **Full note text:** install **KWGT**, add its widget, add one Text layer, and in the text field enter (wrapped in `$...$` so Kustom evaluates it rather than showing it literally): `$wg("/sdcard/notes/today.md", raw)$`. Grant KWGT storage access; if it comes up blank try `$wg("file:///sdcard/notes/today.md", raw)$`. KWGT shows plain text: markdown is not rendered. (`wg(path, raw)` reads a local file; `fl()` is for evaluating formulas, not file reads.)

The mirror is one-way; nothing writes back into the vault. A checkable widget that folds check-offs back into the note is a separate, deliberately-scoped feature.

## Webhook fan-out (cluster side)

If you ever need to redeploy the bridge or rotate the HMAC, the manifests live in `home-config/apps/`:

- `notes-sync-bridge/` — Python webhook receiver, fans out to mosquitto + ntfy
- `ntfy/` — phone push broker
- `mosquitto/` — desktop pub/sub broker
- `forgejo/configmap.yaml` — `[webhook] ALLOWED_HOST_LIST = private,external` permits the LAN bridge

Rotate HMAC:

```bash
NEW=$(head -c 32 /dev/urandom | xxd -p -c 64)
cd ~/dev/home/home-config
sops apps/notes-sync-bridge/secret.yaml         # replace value with $NEW
git add apps/notes-sync-bridge/secret.yaml && git commit -m 'chore: rotate notes-sync HMAC' && git push forgejo master
# update Forgejo webhook to match
TOKEN=$(kubectl --context home-k3s exec -n forgejo deploy/forgejo -- \
    su-exec git forgejo admin user generate-access-token -u kblack0610 -t notes-rotate --raw --scopes "write:repository" | tail -1)
curl -u "kblack0610:$TOKEN" -X PATCH \
  -H 'Content-Type: application/json' \
  -d "{\"config\":{\"secret\":\"$NEW\"}}" \
  https://git.example.internal/api/v1/repos/kblack0610/.notes/hooks/<id>
```

## The sync engine

Every trigger above (notes-watch, notes-mqtt, notes-ntfy, the fallback timer, the Termux cron and boot hook) runs `notes-sync`, which is `store-sync --store notes`: the same engine that syncs `~/.agent` (`~/.local/bin/store-sync`). One run commits every change in `~/.notes`, fetches origin and merges it (merge, never rebase, so the note open in the editor is not rewritten), pushes origin, then pushes backup when the clone has one. Windows is the exception: `notes-sync.ps1` is its own port, still on `git pull --rebase`, and it still reads the `NOTES_SYNC_PRIMARY_REMOTE`, `NOTES_SYNC_BACKUP_REMOTE`, `NOTES_SYNC_MIRROR_REMOTE` and `NOTES_SYNC_BRANCH` environment overrides that the other platforms dropped (board row ar-2741 moves it onto the same rules).

- Log, lock and state: `~/.local/state/notes-sync/` (`sync.log`, which `notes doctor` reads; `conflict`, `conflict-backup`; `backup-failures`).
- `COMPLETE: origin at <sha>, backup at <sha>` means origin holds HEAD. `BACKUP:` means origin was unreachable and the commit went to backup. `SKIP:` means no remote answered and the commits wait for the next sync.
- A merge conflict aborts the merge, keeps every local commit, logs `ERROR: merging origin conflicts in <files>`, and pages once. The same pair is not retried until one side moves.
- A backup that has taken no write for an hour while origin answers pages once, and pages again when it recovers. A conflict with backup pages once and skips backup only; origin keeps syncing.
- The engine needs bash 4 or later; on macOS it runs Homebrew bash (`brew install bash`), since /bin/bash is 3.2.
- A clone checked out on a branch other than `master` syncs nothing and logs `ERROR: ... is on <branch>, not master`.

| Symptom | Cause | Fix |
|---|---|---|
| `ERROR: merging origin conflicts in <file>` and a page | Two devices changed the same lines before either synced | In `~/.notes`: `git merge origin/master`, resolve, commit; the next sync pushes it |
| Page: the notes store's backup has not taken a write for an hour | GitHub refuses the push (auth or a non-fast-forward) | `tail ~/.local/state/notes-sync/sync.log`; `backup failed: <why>` names it |
| A phone stops syncing after its dotfiles clone was updated | Its `notes-sync` wrapper still names the deleted `git-sync-notes.sh` | Re-run `notes-phone-setup` |

## Runtime overrides

`~/.config/notes-sync.env` is read by the units, not by the engine:

```text
NOTES_DIR=$HOME/.notes                    # the vault, read by store-sync and notes-watch
NOTES_MQTT_HOST=mosquitto.example.internal
NOTES_MQTT_PORT=31883
NOTES_MQTT_TOPIC=notes/sync/needed
NOTES_NTFY_URL=https://ntfy.example.internal/notes-sync/raw
```

The remotes are the clone's own (`notes-sync-bootstrap.sh` sets them), and the branch is `master`.

## Validation

```bash
# Remotes look right
git -C ~/.notes remote -v

# Master device:
#   origin  https://git.example.internal/kblack0610/.notes.git
#   backup  git@github.com:Kblack0610/.notes.git
#
# Other devices:
#   origin  https://git.example.internal/kblack0610/.notes.git

# Push side: edit a file, watch the sync log
date >> ~/.notes/inbox/_test.md
tail -f ~/.local/state/notes-sync/sync.log  # Linux, macOS, Termux
Get-Content $env:LOCALAPPDATA\notes-sync\watch.log -Wait         # Windows

# Pull side: push from another device, watch this device fire
journalctl --user -u notes-mqtt -f          # Linux
```
