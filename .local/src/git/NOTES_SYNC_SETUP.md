# Notes Sync Bootstrap

The repo now contains the reusable `~/.notes` sync tooling so a new device can be set up from the dotfiles checkout with one bootstrap command plus credentials.

## Model

- `~/.notes` stays local on each device
- `origin` points to the NAS Git repo
- `backup` points to GitHub
- `notes-sync` handles fetch, auto-commit, rebase, push, and backup push

## Required inputs

You still need to provision two things outside Git:

- an SSH key that can reach the NAS Git repo
- the NAS remote URL, for example `ssh://kblack0610@nas.lan:2222/mnt/nas/private/git/.notes.git`

GitHub backup can stay `git@github.com:Kblack0610/.notes.git`.

## Desktop bootstrap

If `~/.notes` already exists and you only want the tooling installed:

```bash
~/.dotfiles/.local/bin/notes-bootstrap
```

If you want to clone or repoint the repo during bootstrap:

```bash
~/.dotfiles/.local/bin/notes-bootstrap \
  --primary-url ssh://kblack0610@nas.lan:2222/mnt/nas/private/git/.notes.git \
  --backup-url git@github.com:Kblack0610/.notes.git
```

What it does:

- links managed scripts from `~/.dotfiles` into `~/.local` and `~/.config`
- clones `~/.notes` if missing
- or repoints remotes if `~/.notes` already exists
- enables `git-sync-notes.timer` on desktop machines

## Termux bootstrap

After cloning the dotfiles repo in Termux:

```bash
~/.dotfiles/.local/bin/notes-termux-bootstrap \
  --primary-url ssh://kblack0610@nas.lan:2222/mnt/nas/private/git/.notes.git \
  --backup-url git@github.com:Kblack0610/.notes.git
```

What it does:

- installs `git`, `openssh`, `cronie`, `termux-services`, and `termux-tools`
- links the managed notes scripts into the Termux home
- clones or repoints `~/.notes`
- installs an hourly `crond` entry for `notes-sync`
- writes a `~/.termux/boot/notes-sync.sh` hook for unlock/boot sync

## Credentials

Bootstrap does not create or distribute secrets.

Before the first real sync on a new device, make sure one of these is true:

- `~/.ssh/id_notes_sync` is present and authorized on the NAS
- or your normal SSH key already has access to the NAS repo

The sync script automatically uses `~/.ssh/id_notes_sync` when it exists.

## Runtime overrides

An example runtime config lives at `~/.config/notes-sync.env.example`.

If needed, create `~/.config/notes-sync.env` and override:

- `NOTES_SYNC_SSH_KEY`
- `NOTES_SYNC_PRIMARY_REMOTE`
- `NOTES_SYNC_BACKUP_REMOTE`
- `NOTES_SYNC_BRANCH`

## Validation

After bootstrap:

```bash
git -C ~/.notes remote -v
notes-sync
```

Expected remotes:

```text
origin  ssh://kblack0610@nas.lan:2222/mnt/nas/private/git/.notes.git
backup  git@github.com:Kblack0610/.notes.git
```
