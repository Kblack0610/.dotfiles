# NAS-Backed Notes Sync Setup

This setup keeps `~/.notes` local on each machine and uses Git for synchronization:

- `origin` is the NAS-hosted bare repo used for day-to-day sync
- `backup` is GitHub and is pushed after a successful NAS sync
- `notes-sync` is the supported manual command
- `git-sync-notes.timer` provides hourly/background sync

## Why this shape

Do not edit `~/.notes` directly from a mounted NAS share. Keep a local working tree on each device and sync through Git. This preserves fast local Neovim workflows, works offline, and reduces network filesystem edge cases.

## Files

| Path | Purpose |
| --- | --- |
| `~/.local/src/git/git-sync-notes.sh` | Main sync script |
| `~/.local/bin/notes-sync` | Manual command wrapper |
| `~/.local/src/git/notes-sync-bootstrap.sh` | Remote migration/bootstrap helper |
| `~/.config/systemd/user/git-sync-notes.service` | systemd service |
| `~/.config/systemd/user/git-sync-notes.timer` | systemd timer |
| `~/.config/notes-sync.env` | Optional per-machine overrides |

## 1. Create the NAS bare repo

Create a bare Git repo on the NAS over SSH. Example:

```bash
ssh your-nas 'mkdir -p /volume1/git/.notes.git && git init --bare /volume1/git/.notes.git'
```

Use the real host/path for your NAS. The result should be a reachable Git remote URL such as:

```bash
git@your-nas:/volume1/git/.notes.git
```

## 2. Set up SSH credentials

Generate a dedicated key if you want notes sync isolated from other SSH access:

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_notes_sync -N "" -C "notes-sync-automated"
```

Install the public key on:

- the NAS account that hosts the bare repo
- GitHub, if `backup` uses SSH

The sync script automatically uses `~/.ssh/id_notes_sync` when it exists.

## 3. Repoint your existing notes repo

Your current setup already uses `~/.notes` as a Git repo. Reconfigure it so the NAS becomes `origin` and GitHub becomes `backup`:

```bash
~/.local/src/git/notes-sync-bootstrap.sh \
  git@your-nas:/volume1/git/.notes.git \
  git@github.com:Kblack0610/.notes.git
```

If your current `origin` is already GitHub, the bootstrap script will preserve it as `backup` when needed.

Verify:

```bash
git -C ~/.notes remote -v
```

Expected shape:

```text
origin  git@your-nas:/volume1/git/.notes.git
backup  git@github.com:Kblack0610/.notes.git
```

## 4. Optional per-machine overrides

Most setups need no extra config. If a machine needs different settings, create `~/.config/notes-sync.env`:

```bash
NOTES_SYNC_SSH_KEY=$HOME/.ssh/id_notes_sync
NOTES_SYNC_PRIMARY_REMOTE=origin
NOTES_SYNC_BACKUP_REMOTE=backup
```

Supported overrides:

- `NOTES_DIR`
- `NOTES_SYNC_STATE_DIR`
- `NOTES_SYNC_SSH_KEY`
- `NOTES_SYNC_PRIMARY_REMOTE`
- `NOTES_SYNC_BACKUP_REMOTE`
- `NOTES_SYNC_BRANCH`
- `NOTES_SYNC_HOSTNAME`

## 5. Manual sync workflow

Primary command:

```bash
notes-sync
```

The script:

1. fetches from `origin`
2. stages and auto-commits local changes when needed
3. rebases on top of `origin` when histories diverge
4. pushes to `origin`
5. pushes the same branch to `backup` when configured

If the rebase conflicts, the script stops and leaves the repo for manual resolution.

## 6. Enable background sync

```bash
systemctl --user daemon-reload
systemctl --user enable --now git-sync-notes.timer
```

Useful commands:

```bash
systemctl --user status git-sync-notes.timer
systemctl --user start git-sync-notes.service
journalctl --user -eu git-sync-notes.service
```

## 7. New machine bootstrap

On a new machine:

```bash
git clone git@your-nas:/volume1/git/.notes.git ~/.notes
git -C ~/.notes remote add backup git@github.com:Kblack0610/.notes.git
systemctl --user enable --now git-sync-notes.timer
notes-sync
```

If you use the dedicated SSH key, copy or provision `~/.ssh/id_notes_sync` first.

## Validation

Test the full flow with two machines:

1. Edit a file on machine A and run `notes-sync`
2. Run `notes-sync` on machine B and confirm the change appears
3. Confirm `git -C ~/.notes log --oneline -n 3` shows the auto-commit when local changes were present
4. Confirm `git -C ~/.notes remote -v` still lists both `origin` and `backup`

## Failure modes

- If the NAS is unavailable, sync stops before any backup push.
- If GitHub is unavailable, the `origin` push still completes but the backup push fails loudly.
- If two machines edit the same note concurrently, the script stops on rebase conflict and requires manual resolution.
