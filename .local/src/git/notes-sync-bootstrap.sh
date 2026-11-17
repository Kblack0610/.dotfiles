#!/bin/bash

set -euo pipefail

NOTES_DIR="${NOTES_DIR:-$HOME/.notes}"
# The names store-sync pushes to.
PRIMARY_REMOTE=origin
BACKUP_REMOTE=backup

usage() {
    cat <<'EOF'
Usage:
  notes-sync-bootstrap.sh <nas-remote-url> [github-backup-url]

Examples:
  notes-sync-bootstrap.sh ssh://kblack0610@nas.lan:2222/mnt/nas/private/git/.notes.git
  notes-sync-bootstrap.sh ssh://kblack0610@nas.lan:2222/mnt/nas/private/git/.notes.git git@github.com:Kblack0610/.notes.git
EOF
}

if [ "${1:-}" = "" ]; then
    usage
    exit 1
fi

NAS_REMOTE_URL="$1"
BACKUP_REMOTE_URL="${2:-}"

if [ ! -d "$NOTES_DIR/.git" ]; then
    echo "ERROR: $NOTES_DIR is not a git repository" >&2
    exit 1
fi

cd "$NOTES_DIR"

existing_origin=""
if git remote get-url "$PRIMARY_REMOTE" >/dev/null 2>&1; then
    existing_origin=$(git remote get-url "$PRIMARY_REMOTE")
fi

if [ -n "$existing_origin" ] && [ "$existing_origin" != "$NAS_REMOTE_URL" ] && ! git remote get-url "$BACKUP_REMOTE" >/dev/null 2>&1; then
    git remote rename "$PRIMARY_REMOTE" "$BACKUP_REMOTE"
    echo "Renamed existing $PRIMARY_REMOTE remote to $BACKUP_REMOTE"
fi

if git remote get-url "$PRIMARY_REMOTE" >/dev/null 2>&1; then
    git remote set-url "$PRIMARY_REMOTE" "$NAS_REMOTE_URL"
else
    git remote add "$PRIMARY_REMOTE" "$NAS_REMOTE_URL"
fi

if [ -n "$BACKUP_REMOTE_URL" ]; then
    if git remote get-url "$BACKUP_REMOTE" >/dev/null 2>&1; then
        git remote set-url "$BACKUP_REMOTE" "$BACKUP_REMOTE_URL"
    else
        git remote add "$BACKUP_REMOTE" "$BACKUP_REMOTE_URL"
    fi
fi

# An https origin authenticates from ~/.git-credentials. The shared ~/.gitconfig names a helper
# only on macOS (the keychain), so elsewhere this clone gets the file-based store helper of its
# own, or every unattended sync fails auth. Repo-local, so the shared config is untouched.
case "$NAS_REMOTE_URL" in
    https://*)
        if [ "$(uname)" != Darwin ] && ! git config --local --get-all credential.helper | grep -qx store; then
            git config --local credential.helper ""
            git config --local --add credential.helper store
            echo "Enabled the file-based 'store' credential helper for this clone"
        fi
        ;;
esac

echo "Configured notes remotes:"
git remote -v
