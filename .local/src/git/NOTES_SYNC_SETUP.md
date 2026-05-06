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
   │ Forgejo @ git.kblab.me  (primary git, in-cluster)  │
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
```

## Required inputs

You provision two things outside git:

- An identity that can push to Forgejo (HTTPS token in `~/.git-credentials` is fine)
- The Forgejo URL: `https://git.kblab.me/kblack0610/.notes.git`

The master device additionally has `backup` → `git@github.com:Kblack0610/.notes.git`. Other devices skip this.

## Desktop bootstrap (Linux + macOS)

```bash
NOTES_PRIMARY_REMOTE_URL=https://git.kblab.me/kblack0610/.notes.git \
~/.dotfiles/.local/bin/notes-bootstrap
```

`notes-bootstrap` auto-detects Linux vs macOS and does the right thing:

- **Linux** — installs the systemd user units (`git-sync-notes.timer` 5-min fallback, `notes-watch` for inotify push, `notes-mqtt` for the pull subscriber).
- **macOS** — installs the launchd plists (`com.kblack.git-sync-notes`, `com.kblack.notes-watch` using `WatchPaths`, `com.kblack.notes-mqtt`) into `~/Library/LaunchAgents/`.

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
$env:NOTES_PRIMARY_REMOTE_URL = 'https://git.kblab.me/kblack0610/.notes.git'
~\.dotfiles\.local\src\installation_scripts\windows\setup_notes_sync.ps1
```

Registers three Scheduled Tasks:

- `notes-sync-fallback` — every 5 minutes
- `notes-watch` — at logon, restart on failure (FileSystemWatcher with 3s debounce)
- `notes-mqtt` — at logon, restart on failure (`mosquitto_sub` subscriber)

Run a task manually: `Start-ScheduledTask -TaskName notes-sync-fallback`.

## Termux (Android) bootstrap

```bash
~/.dotfiles/.local/bin/notes-termux-bootstrap \
  --primary-url https://git.kblab.me/kblack0610/.notes.git
```

Plus install the official **ntfy Android app** and subscribe to:

```
https://ntfy.kblab.me/notes-sync
```

(Tailscale always-on lets the phone reach `ntfy.kblab.me` even on cellular.)

The ntfy notifications use the OS push channel — near-zero battery cost. The Termux side keeps a 5-min cron + a `~/.termux/boot/notes-sync.sh` hook as fallback.

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
  https://git.kblab.me/api/v1/repos/kblack0610/.notes/hooks/<id>
```

## Runtime overrides

Override at `~/.config/notes-sync.env`:

```text
NOTES_SYNC_PRIMARY_REMOTE=origin
NOTES_SYNC_BACKUP_REMOTE=backup           # only on the master device
NOTES_SYNC_MIRROR_REMOTE=nas              # only during the NAS deprecation window
NOTES_SYNC_BRANCH=master
NOTES_MQTT_HOST=mosquitto.kblab.me
NOTES_MQTT_PORT=31883
NOTES_MQTT_TOPIC=notes/sync/needed
```

## Validation

```bash
# Remotes look right
git -C ~/.notes remote -v

# Master device:
#   origin  https://git.kblab.me/kblack0610/.notes.git
#   backup  git@github.com:Kblack0610/.notes.git
#   nas     ssh://...nas.lan:2222/...    (only during deprecation window)
#
# Other devices:
#   origin  https://git.kblab.me/kblack0610/.notes.git

# Push side: edit a file, watch the sync log
date >> ~/.notes/inbox/_test.md
journalctl --user -u notes-watch -f         # Linux
log stream --predicate 'subsystem == "com.kblack.notes-watch"'   # macOS
Get-Content $env:LOCALAPPDATA\notes-sync\watch.log -Wait         # Windows

# Pull side: push from another device, watch this device fire
journalctl --user -u notes-mqtt -f          # Linux
```

## Migrating an existing device off the legacy NAS bare repo

```bash
cd ~/.notes
git remote rename origin nas                                       # legacy NAS becomes mirror
git remote add origin https://git.kblab.me/kblack0610/.notes.git   # Forgejo is primary now
git fetch origin
git push -u origin master
echo "NOTES_SYNC_MIRROR_REMOTE=nas" >> ~/.config/notes-sync.env    # keep mirror push for 2 weeks
```

After ~2 weeks of clean operation the `nas` remote can be dropped and the bare repo on `asus-laptop:/home/kblack0610/git/.notes.git` archived.
