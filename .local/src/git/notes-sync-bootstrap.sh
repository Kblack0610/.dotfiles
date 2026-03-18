#!/bin/bash

set -euo pipefail

NOTES_DIR="${NOTES_DIR:-$HOME/.notes}"
PRIMARY_REMOTE="${NOTES_SYNC_PRIMARY_REMOTE:-origin}"
BACKUP_REMOTE="${NOTES_SYNC_BACKUP_REMOTE:-backup}"

usage() {
    cat <<'EOF'
Usage:
  notes-sync-bootstrap.sh <nas-remote-url> [github-backup-url]

Examples:
  notes-sync-bootstrap.sh git@nas.local:/volume1/git/.notes.git
  notes-sync-bootstrap.sh git@nas.local:/volume1/git/.notes.git git@github.com:Kblack0610/.notes.git
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
    existing_origin=""
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

echo "Configured notes remotes:"
git remote -v
