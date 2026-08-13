#!/bin/bash
# git-sync-agent.sh - Enhanced autosync for ~/.agent plans
#
# Improvements over notes sync:
# - flock locking (prevents concurrent syncs)
# - Rebase-first strategy (cleaner history)
# - Conflict backup (saves local version before accepting remote)
# - Hostname tracking (identifies which machine made changes)
# - Logging (tracks sync history)
# - Network check (skips sync if offline)

set -e

AGENT_DIR="$HOME/.agent"
SYNC_DIR="$AGENT_DIR/.sync"
LOG_FILE="$SYNC_DIR/sync.log"
LOCK_FILE="$SYNC_DIR/lock"
SSH_KEY="$HOME/.ssh/id_agent_sync"
REMOTE="origin"
BRANCH="master"

# Logging function
log() {
    mkdir -p "$SYNC_DIR"
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] [$(hostname)] $1" >> "$LOG_FILE"
    echo "$1"
}

# Rotate log if too large (>1MB)
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

# Setup
mkdir -p "$SYNC_DIR"
export GIT_SSH_COMMAND="ssh -i $SSH_KEY -o IdentitiesOnly=yes -o BatchMode=yes -o ConnectTimeout=10"

# Acquire lock (non-blocking)
exec 200>"$LOCK_FILE"
if ! flock -n 200; then
    log "SKIP: Another sync in progress"
    exit 0
fi

cd "$AGENT_DIR" || { log "ERROR: Cannot cd to $AGENT_DIR"; exit 1; }

# Append-only logs must UNION-merge, or the conflict path below eats one machine's half.
#
# The conflict resolver accepts remote wholesale (`git checkout --theirs .`) and saves the
# local side to `<file>.conflict.<host>.<ts>` — a backup nobody reads. For a file where
# both machines legitimately APPENDED different lines, that is silent data loss, and the
# board event log is exactly that shape: two machines observing their own board edits.
#
# `merge=union` is git's built-in driver for this case (keep both sides' added lines, no
# conflict markers, no custom driver to install), so these files never reach the resolver
# at all. Written here rather than shipped as a dotfile because ~/.agent is runtime state
# with its own git repo, not a stow target — and idempotently, so it self-heals on a fresh
# clone or if someone deletes it.
if [ ! -f .gitattributes ] || ! grep -q 'board-events.jsonl' .gitattributes 2>/dev/null; then
    printf '%s\n' \
      '# Append-only event logs: keep BOTH machines lines on divergence.' \
      '# Without this, the conflict path in git-sync-agent.sh accepts remote and' \
      '# strands the local side in a .conflict backup nobody reads.' \
      '*board-events.jsonl merge=union' \
      >> .gitattributes
    log "SETUP: added merge=union for board-events.jsonl"
fi

# Check for network connectivity (quick test)
if ! ssh -i "$SSH_KEY" -o BatchMode=yes -o ConnectTimeout=5 -o StrictHostKeyChecking=accept-new git@github.com 2>&1 | grep -qi "successfully authenticated"; then
    log "SKIP: No network or GitHub unavailable"
    exit 0
fi

log "START: Beginning sync"

# Fetch latest
if ! git fetch "$REMOTE" "$BRANCH" 2>&1; then
    log "ERROR: Fetch failed"
    exit 1
fi

# Stage local changes
git add .

# Check if there are local changes to commit
if ! git diff --cached --quiet; then
    git commit -m "Auto-commit $(hostname) $(date +%Y-%m-%d_%H:%M)" || true
    log "COMMIT: Local changes committed"
fi

# Get status relative to remote
LOCAL=$(git rev-parse HEAD)
REMOTE_REF=$(git rev-parse "$REMOTE/$BRANCH" 2>/dev/null || echo "")

if [ -z "$REMOTE_REF" ]; then
    log "WARN: Remote branch not found, pushing local"
    git push -u "$REMOTE" "$BRANCH"
    log "COMPLETE: Pushed to new remote branch"
    date +%s > "$SYNC_DIR/last-sync"
    rotate_log
    exit 0
fi

BASE=$(git merge-base HEAD "$REMOTE/$BRANCH" 2>/dev/null || echo "")

if [ "$LOCAL" = "$REMOTE_REF" ]; then
    log "SYNC: Already up to date"
elif [ "$LOCAL" = "$BASE" ]; then
    # We're behind, fast-forward
    git merge --ff-only "$REMOTE/$BRANCH"
    log "SYNC: Fast-forwarded to remote"
elif [ "$REMOTE_REF" = "$BASE" ]; then
    # We're ahead, just push
    git push "$REMOTE" "$BRANCH"
    log "SYNC: Pushed local changes"
else
    # Diverged - try rebase first
    log "SYNC: Branches diverged, attempting rebase"
    if git rebase "$REMOTE/$BRANCH" 2>&1; then
        git push "$REMOTE" "$BRANCH"
        log "SYNC: Rebased and pushed"
    else
        # Rebase failed, fallback to merge
        git rebase --abort 2>/dev/null || true
        log "SYNC: Rebase failed, trying merge"

        if git merge "$REMOTE/$BRANCH" -m "Auto-merge $(hostname) $(date +%Y-%m-%d)" 2>&1; then
            git push "$REMOTE" "$BRANCH"
            log "SYNC: Merged and pushed"
        else
            # Merge conflict - backup and accept remote
            log "CONFLICT: Saving local versions as backups"

            git diff --name-only --diff-filter=U 2>/dev/null | while read -r file; do
                if [ -n "$file" ]; then
                    backup="$file.conflict.$(hostname).$(date +%Y%m%d%H%M%S)"
                    git show "HEAD:$file" > "$backup" 2>/dev/null || true
                    log "BACKUP: $backup"
                fi
            done

            git checkout --theirs . 2>/dev/null || true
            git add .
            git commit -m "Auto-resolve: accepted remote on $(hostname)" || true
            git push "$REMOTE" "$BRANCH"
            log "CONFLICT: Resolved by accepting remote, backups saved"
        fi
    fi
fi

# Record successful sync
date +%s > "$SYNC_DIR/last-sync"
log "COMPLETE: Sync finished"

rotate_log
