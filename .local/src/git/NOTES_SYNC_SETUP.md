# Automated Git Notes Sync Setup

This guide explains how to set up automatic synchronization of `~/.notes` with GitHub across multiple machines.

## Overview

The sync system:
- Pulls latest changes from remote
- Commits any local changes with a date-stamped message
- Pushes to remote
- Runs automatically on a schedule (hourly on Linux)

## Prerequisites

- Git installed
- `~/.notes` directory initialized as a git repo with remote set up
- SSH access to GitHub

---

## SSH Deploy Key Setup

A dedicated passphrase-less SSH key is used for automated sync. This key should be added as a **deploy key** on the GitHub repository.

### Generate the key (first machine only)

```bash
ssh-keygen -t ed25519 -f ~/.ssh/id_notes_sync -N "" -C "notes-sync-automated"
```

### Add to GitHub

1. Go to: `https://github.com/YOUR_USERNAME/YOUR_NOTES_REPO/settings/keys`
2. Click "Add deploy key"
3. Title: `notes-sync-automated`
4. Paste contents of `~/.ssh/id_notes_sync.pub`
5. **Check "Allow write access"**
6. Click "Add key"

### Copy key to other machines

Copy the private key to each machine:
```bash
# From source machine
scp ~/.ssh/id_notes_sync user@newmachine:~/.ssh/
```

Set correct permissions on the new machine:
```bash
chmod 600 ~/.ssh/id_notes_sync
```

---

## Linux Setup (systemd)

### 1. Create the sync script

Save to `~/.local/src/git/git-sync-notes.sh`:

```bash
#!/bin/bash
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_notes_sync -o IdentitiesOnly=yes -o BatchMode=yes"

cd "$HOME/.notes" || exit 1

git pull origin master || true
git add .
git commit -m "Auto-commit $(date +%Y-%m-%d)" || true
git push origin master
```

Make it executable:
```bash
chmod +x ~/.local/src/git/git-sync-notes.sh
```

### 2. Create systemd service

Save to `~/.config/systemd/user/git-sync-notes.service`:

```ini
[Unit]
Description=Git Auto Push and Pull Service
After=network.target

[Service]
Type=oneshot
ExecStart=%h/.local/src/git/git-sync-notes.sh

[Install]
WantedBy=default.target
```

Note: `%h` expands to your home directory in systemd.

### 3. Create systemd timer

Save to `~/.config/systemd/user/git-sync-notes.timer`:

```ini
[Unit]
Description=Run Git Auto Push and Pull periodically

[Timer]
OnCalendar=hourly
AccuracySec=1

[Install]
WantedBy=timers.target
```

### 4. Enable and start

```bash
systemctl --user daemon-reload
systemctl --user enable --now git-sync-notes.timer
```

### 5. Verify

```bash
# Check timer status
systemctl --user status git-sync-notes.timer

# Manual test run
systemctl --user start git-sync-notes.service

# View logs
journalctl --user -eu git-sync-notes.service
```

---

## Android Setup (Termux)

### 1. Install required packages

```bash
pkg install git openssh cronie termux-services
```

### 2. Set up SSH key

Copy `id_notes_sync` from another machine or generate new one:
```bash
# Copy from computer (run on computer)
scp ~/.ssh/id_notes_sync your-phone-ip:~/.ssh/

# Or use Termux:API to transfer
```

Set permissions:
```bash
chmod 600 ~/.ssh/id_notes_sync
```

### 3. Clone your notes repo

```bash
export GIT_SSH_COMMAND="ssh -i ~/.ssh/id_notes_sync -o IdentitiesOnly=yes"
git clone git@github.com:YOUR_USERNAME/YOUR_NOTES_REPO.git ~/.notes
```

### 4. Create sync script

Save to `~/.local/bin/git-sync-notes.sh`:

```bash
#!/data/data/com.termux/files/usr/bin/bash
export GIT_SSH_COMMAND="ssh -i $HOME/.ssh/id_notes_sync -o IdentitiesOnly=yes -o BatchMode=yes"

cd "$HOME/.notes" || exit 1

git pull origin master || true
git add .
git commit -m "Auto-commit $(date +%Y-%m-%d)" || true
git push origin master
```

Make executable:
```bash
chmod +x ~/.local/bin/git-sync-notes.sh
```

### 5. Set up cron job

Start crond service:
```bash
sv-enable crond
```

Edit crontab:
```bash
crontab -e
```

Add (runs every hour):
```
0 * * * * ~/.local/bin/git-sync-notes.sh
```

### Alternative: Termux:Boot (run on device unlock)

1. Install Termux:Boot from F-Droid
2. Create `~/.termux/boot/sync-notes.sh`:
```bash
#!/data/data/com.termux/files/usr/bin/bash
sleep 10  # Wait for network
~/.local/bin/git-sync-notes.sh
```
3. Make executable: `chmod +x ~/.termux/boot/sync-notes.sh`

---

## macOS Setup (launchd)

### 1. Create sync script

Save to `~/.local/src/git/git-sync-notes.sh` (same as Linux version).

### 2. Create launchd plist

Save to `~/Library/LaunchAgents/com.user.git-sync-notes.plist`:

```xml
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.user.git-sync-notes</string>
    <key>ProgramArguments</key>
    <array>
        <string>/bin/bash</string>
        <string>-c</string>
        <string>~/.local/src/git/git-sync-notes.sh</string>
    </array>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>RunAtLoad</key>
    <true/>
    <key>StandardOutPath</key>
    <string>/tmp/git-sync-notes.log</string>
    <key>StandardErrorPath</key>
    <string>/tmp/git-sync-notes.err</string>
</dict>
</plist>
```

### 3. Load the agent

```bash
launchctl load ~/Library/LaunchAgents/com.user.git-sync-notes.plist
```

---

## Troubleshooting

### Permission denied (publickey)
- Verify the deploy key is added to GitHub with write access
- Check key permissions: `chmod 600 ~/.ssh/id_notes_sync`
- Test manually: `GIT_SSH_COMMAND="ssh -i ~/.ssh/id_notes_sync" git -C ~/.notes pull`

### Service fails silently
- Check logs: `journalctl --user -eu git-sync-notes.service`
- Run script manually to see errors: `~/.local/src/git/git-sync-notes.sh`

### Merge conflicts
The script uses `|| true` to continue on errors. If you have conflicts:
```bash
cd ~/.notes
git status
# Resolve conflicts manually
git add .
git commit -m "Resolve conflicts"
git push
```

### Timer not running
```bash
# Check if timer is enabled
systemctl --user list-timers

# Re-enable if needed
systemctl --user enable --now git-sync-notes.timer
```

---

## Files Reference

| File | Purpose |
|------|---------|
| `~/.ssh/id_notes_sync` | Private SSH key (keep secure!) |
| `~/.ssh/id_notes_sync.pub` | Public key (added to GitHub) |
| `~/.local/src/git/git-sync-notes.sh` | Sync script |
| `~/.config/systemd/user/git-sync-notes.service` | systemd service |
| `~/.config/systemd/user/git-sync-notes.timer` | systemd timer |
