#!/bin/bash

set -euo pipefail

NOTES_DIR="${NOTES_DIR:-$HOME/.notes}"
STATE_DIR="${NOTES_SYNC_STATE_DIR:-$HOME/.local/state/notes-sync}"
LOG_FILE="$STATE_DIR/sync.log"
LOCK_FILE="$STATE_DIR/lock"
SSH_KEY="${NOTES_SYNC_SSH_KEY:-$HOME/.ssh/id_notes_sync}"
PRIMARY_REMOTE="${NOTES_SYNC_PRIMARY_REMOTE:-origin}"
BACKUP_REMOTE="${NOTES_SYNC_BACKUP_REMOTE:-backup}"
MIRROR_REMOTE="${NOTES_SYNC_MIRROR_REMOTE:-}"
HOST_TAG="${NOTES_SYNC_HOSTNAME:-$(hostname -s 2>/dev/null || hostname 2>/dev/null || uname -n 2>/dev/null || echo host)}"
CONNECT_TIMEOUT="${NOTES_SYNC_CONNECT_TIMEOUT:-10}"
# Consecutive backup-push failures before we alert. The timer runs every 5 min,
# so 12 is roughly an hour of a genuinely dead backup rather than one bad Wi-Fi
# moment. See track_backup_push below.
BACKUP_ALERT_AFTER="${NOTES_SYNC_BACKUP_ALERT_AFTER:-12}"
BACKUP_FAIL_FILE="$STATE_DIR/backup-failures"

log() {
    mkdir -p "$STATE_DIR"
    printf '[%s] [%s] %s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$HOST_TAG" "$1" | tee -a "$LOG_FILE"
}

notify() {
    # Resolve explicitly: under systemd the manager's PATH is not the login PATH,
    # and an alert that silently evaporates is the failure this function exists to
    # prevent. agent-notify always exits 0, but never let it fail the sync anyway.
    local n
    n=$(command -v agent-notify 2>/dev/null || true)
    [ -n "$n" ] || n="$HOME/.local/bin/agent-notify"
    [ -x "$n" ] || return 0
    "$n" -t "notes-sync" -p "$1" "$2" >/dev/null 2>&1 || true
}

backup_failures() {
    local n
    n=$(cat "$BACKUP_FAIL_FILE" 2>/dev/null || echo 0)
    case "$n" in ''|*[!0-9]*) n=0 ;; esac
    printf '%s' "$n"
}

# Backup is redundancy: one failed push must not fail the sync, and that is why
# the failure below is non-fatal. But "non-fatal" silently swallowed a month of
# non-fast-forward rejections once already, which is how the offsite backup went
# stale from 2026-06-17 without anyone noticing. So count CONSECUTIVE failures and
# alert once on the way out and once on recovery: state changes, not every tick,
# or the alert becomes noise and gets ignored just as thoroughly as the WARN was.
track_backup_push() {
    local prev
    prev=$(backup_failures)
    if [ "$1" -eq 0 ]; then
        if [ "$prev" -ge "$BACKUP_ALERT_AFTER" ]; then
            notify normal "Notes backup remote '$BACKUP_REMOTE' recovered on $HOST_TAG after $prev failed pushes."
        fi
        printf '0\n' > "$BACKUP_FAIL_FILE"
        log "BACKUP: Updated $BACKUP_REMOTE/$BRANCH"
    else
        local n=$((prev + 1))
        printf '%s\n' "$n" > "$BACKUP_FAIL_FILE"
        log "WARN: Backup push to '$BACKUP_REMOTE' failed (non-fatal, $n consecutive)"
        if [ "$n" -eq "$BACKUP_ALERT_AFTER" ]; then
            notify high "Notes backup remote '$BACKUP_REMOTE' has failed $n consecutive pushes on $HOST_TAG. The offsite backup is going stale. See $LOG_FILE"
        fi
    fi
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
    # Only force the dedicated key for SSH remotes; for HTTPS origins GIT_SSH_COMMAND
    # is irrelevant and the BatchMode key would just be dead weight.
    case "$(git remote get-url "$PRIMARY_REMOTE" 2>/dev/null)" in
        ssh://*|*@*:*)
            if [ -f "$SSH_KEY" ]; then
                export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=$CONNECT_TIMEOUT -o StrictHostKeyChecking=accept-new"
            fi
            ;;
    esac
}

ensure_https_credentials() {
    # The shared ~/.gitconfig pins credential.helper=osxkeychain (for macOS). On hosts
    # where that helper binary is absent (Linux), git can't authenticate HTTPS remotes
    # non-interactively and sync silently fails. Fall back to the file-based 'store'
    # helper there. Idempotent and repo-local, so it never touches the shared config.
    case "$(git remote get-url "$PRIMARY_REMOTE" 2>/dev/null)" in
        https://*)
            if ! command -v git-credential-osxkeychain >/dev/null 2>&1 \
               && ! git config --get-all credential.helper | grep -qx store; then
                git config credential.helper ""        # reset inherited helpers for this repo
                git config --add credential.helper store
                log "AUTH: enabled file-based 'store' credential helper for HTTPS sync"
            fi
            ;;
    esac
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

ensure_https_credentials

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
    # Backup is redundancy; a failure here must not undo a successful primary sync.
    if git push "$BACKUP_REMOTE" "$BRANCH" 2>>"$LOG_FILE"; then
        track_backup_push 0
    else
        track_backup_push 1
    fi
else
    log "SKIP: Backup remote '$BACKUP_REMOTE' is not configured"
fi

if [ -n "$MIRROR_REMOTE" ]; then
    if git_remote_exists "$MIRROR_REMOTE"; then
        if git push "$MIRROR_REMOTE" "$BRANCH" 2>>"$LOG_FILE"; then
            log "MIRROR: Updated $MIRROR_REMOTE/$BRANCH"
        else
            log "WARN: Mirror push to '$MIRROR_REMOTE' failed (non-fatal)"
        fi
    else
        log "SKIP: Mirror remote '$MIRROR_REMOTE' is set but not configured"
    fi
fi

log "COMPLETE: Notes sync finished"
rotate_log
