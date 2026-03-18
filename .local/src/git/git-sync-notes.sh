#!/bin/bash

set -euo pipefail

NOTES_DIR="${NOTES_DIR:-$HOME/.notes}"
STATE_DIR="${NOTES_SYNC_STATE_DIR:-$HOME/.local/state/notes-sync}"
LOG_FILE="$STATE_DIR/sync.log"
LOCK_FILE="$STATE_DIR/lock"
SSH_KEY="${NOTES_SYNC_SSH_KEY:-$HOME/.ssh/id_notes_sync}"
PRIMARY_REMOTE="${NOTES_SYNC_PRIMARY_REMOTE:-origin}"
BACKUP_REMOTE="${NOTES_SYNC_BACKUP_REMOTE:-backup}"
HOST_TAG="${NOTES_SYNC_HOSTNAME:-$(hostname -s 2>/dev/null || hostname)}"
CONNECT_TIMEOUT="${NOTES_SYNC_CONNECT_TIMEOUT:-10}"

log() {
    mkdir -p "$STATE_DIR"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$HOST_TAG" "$1" | tee -a "$LOG_FILE"
}

rotate_log() {
    if [ -f "$LOG_FILE" ]; then
        local size
        size=$(stat -c%s "$LOG_FILE" 2>/dev/null || stat -f%z "$LOG_FILE" 2>/dev/null || echo 0)
        if [ "$size" -gt 1048576 ]; then
            tail -1000 "$LOG_FILE" > "$LOG_FILE.tmp"
            mv "$LOG_FILE.tmp" "$LOG_FILE"
        fi
    fi
}

git_remote_exists() {
    git remote get-url "$1" >/dev/null 2>&1
}

setup_ssh() {
    if [ -f "$SSH_KEY" ]; then
        export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=$CONNECT_TIMEOUT -o StrictHostKeyChecking=accept-new"
    fi
}

mkdir -p "$STATE_DIR"
rotate_log

exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: Another notes sync is already running"
    exit 0
fi

if [ ! -d "$NOTES_DIR/.git" ]; then
    log "ERROR: $NOTES_DIR is not a git repository"
    exit 1
fi

cd "$NOTES_DIR"
setup_ssh

if ! git_remote_exists "$PRIMARY_REMOTE"; then
    log "ERROR: Primary remote '$PRIMARY_REMOTE' is not configured"
    exit 1
fi

BRANCH="${NOTES_SYNC_BRANCH:-$(git symbolic-ref --quiet --short HEAD 2>/dev/null || git rev-parse --abbrev-ref HEAD)}"
if [ -z "$BRANCH" ] || [ "$BRANCH" = "HEAD" ]; then
    log "ERROR: Unable to determine the current branch"
    exit 1
fi

backup_enabled=0
if git_remote_exists "$BACKUP_REMOTE"; then
    backup_enabled=1
fi

log "START: Syncing $NOTES_DIR on branch $BRANCH"

remote_branch_exists=0
if git ls-remote --exit-code --heads "$PRIMARY_REMOTE" "$BRANCH" >/dev/null 2>&1; then
    remote_branch_exists=1
fi

if [ "$remote_branch_exists" -eq 1 ]; then
    if ! git fetch "$PRIMARY_REMOTE" "$BRANCH"; then
        log "ERROR: Fetch failed for $PRIMARY_REMOTE/$BRANCH"
        exit 1
    fi
else
    log "INFO: Remote branch $PRIMARY_REMOTE/$BRANCH does not exist yet"
fi

git add -A
if ! git diff --cached --quiet; then
    git commit -m "Auto-commit $HOST_TAG $(date '+%Y-%m-%d_%H:%M:%S')"
    log "COMMIT: Captured local note changes"
fi

if [ "$remote_branch_exists" -eq 0 ]; then
    git push -u "$PRIMARY_REMOTE" "$BRANCH"
    log "PUSH: Created $PRIMARY_REMOTE/$BRANCH"
else
    local_ref=$(git rev-parse HEAD)
    remote_ref=$(git rev-parse "$PRIMARY_REMOTE/$BRANCH")
    base_ref=$(git merge-base HEAD "$PRIMARY_REMOTE/$BRANCH")

    if [ "$local_ref" = "$remote_ref" ]; then
        log "SYNC: Already up to date with $PRIMARY_REMOTE/$BRANCH"
    elif [ "$local_ref" = "$base_ref" ]; then
        git merge --ff-only "$PRIMARY_REMOTE/$BRANCH"
        log "SYNC: Fast-forwarded from $PRIMARY_REMOTE/$BRANCH"
    elif [ "$remote_ref" = "$base_ref" ]; then
        log "SYNC: Local branch is ahead of $PRIMARY_REMOTE/$BRANCH"
    else
        log "SYNC: Diverged from $PRIMARY_REMOTE/$BRANCH, attempting rebase"
        if git rebase "$PRIMARY_REMOTE/$BRANCH"; then
            log "SYNC: Rebased local commits on top of $PRIMARY_REMOTE/$BRANCH"
        else
            git rebase --abort 2>/dev/null || true
            log "ERROR: Rebase conflict detected; resolve manually in $NOTES_DIR"
            exit 1
        fi
    fi

    local_ref=$(git rev-parse HEAD)
    remote_ref=$(git rev-parse "$PRIMARY_REMOTE/$BRANCH")
    if [ "$local_ref" != "$remote_ref" ]; then
        git push "$PRIMARY_REMOTE" "$BRANCH"
        log "PUSH: Updated $PRIMARY_REMOTE/$BRANCH"
    fi
fi

if [ "$backup_enabled" -eq 1 ]; then
    git push "$BACKUP_REMOTE" "$BRANCH"
    log "BACKUP: Updated $BACKUP_REMOTE/$BRANCH"
else
    log "SKIP: Backup remote '$BACKUP_REMOTE' is not configured"
fi

log "COMPLETE: Notes sync finished"
rotate_log
