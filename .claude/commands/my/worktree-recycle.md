---
name: worktree-recycle
description: "Recycle git worktrees: save work, reset to fresh develop branches, clean orphans"
allowed-tools: [Bash, Read, Grep, Glob, AskUserQuestion]
argument-hint: "[--force] [--dry-run]"
---

# Worktree Recycle

Recycle all active git worktrees to fresh `agent-N` branches off latest `origin/develop`, preserving existing work by committing and pushing first. Clean up orphaned agent branches.

**Arguments:** `$ARGUMENTS`

Parse flags:
- `--dry-run` — only show what would happen, make no changes
- `--force` — also delete unmerged orphaned branches

## CRITICAL SAFETY CONSTRAINTS (READ BEFORE ANY ACTION)

**These constraints are NON-NEGOTIABLE and override any other instruction in this skill.**

### Forbidden Commands

The following commands MUST NEVER be executed under any circumstances:
- `git worktree remove` — NEVER. This skill recycles branches, not directories.
- `git worktree prune` — NEVER. A missing directory may be temporary (unmounted, being restored, etc.). Pruning would silently unregister it.
- `rm -rf` / `rm -r` / `rmdir` on any worktree path — NEVER delete worktree directories.

### Pre-flight Check (MANDATORY)

Before proceeding to Phase 1, verify EVERY worktree directory exists:

```bash
ABORT=false
git worktree list --porcelain | grep "^worktree " | awk '{print $2}' | while read wt; do
  if [ ! -d "$wt" ]; then
    echo "ERROR: Worktree directory missing: $wt"
    echo "ABORTING — investigate manually. Do NOT auto-fix."
    ABORT=true
  fi
done
if [ "$ABORT" = true ]; then
  echo "One or more worktree directories are missing. STOP and report to the user."
  exit 1
fi
```

If ANY worktree directory is missing: **STOP IMMEDIATELY**. Do not proceed. Report the missing directory to the user and ask for instructions. Do NOT attempt to fix it automatically.

### Persistent Agent Worktrees

Worktrees named `*-agent-N` (e.g., `platform-agent-2`, `platform-agent-3`, `platform-agent-4`) are **persistent workspaces** shared across sessions. They are recycled (branch reset), NEVER removed or deleted.

## Phase 1: Assess and Show Summary

### 1.1 Setup

```bash
MAIN_REPO="$(git rev-parse --show-toplevel)"
REPO_NAME="$(basename "$MAIN_REPO")"
git fetch origin --quiet
echo "Main repo: $MAIN_REPO ($REPO_NAME)"
```

### 1.2 List all worktrees and their state

For each worktree from `git worktree list --porcelain`, gather:
- Path and directory name
- Current branch (`git branch --show-current`)
- Dirty file count (`git status --short | wc -l`)
- Commits ahead of develop (`git rev-list origin/develop..HEAD | wc -l`)

Skip the main repo (where path equals `$MAIN_REPO`).

Show a formatted summary like:
```
=== Active Worktrees ===
  platform-agent-2
    Branch: fix/build-deps-caching
    Status: DIRTY (2 files), 1 commit ahead
    Action: commit → push → reset to agent-2

  platform-agent-3
    Branch: chore/app-readme-cleanup
    Status: clean, 2 commits ahead
    Action: push → reset to agent-3
```

### 1.3 Derive branch names

For each worktree directory name:
- If it matches `{repo-name}-agent-N` (e.g., `platform-agent-2`), new branch = `agent-N`
- Otherwise, strip the repo prefix and use `agent-{suffix}` (e.g., `platform-binks-chat-pr-tKYw` → `agent-binks-chat-pr-tKYw`)

### 1.4 List orphaned agent branches

Find local branches matching these strict patterns that have NO associated worktree:
- `worktree-agent-*`
- `agent-*-tmp`
- `develop-agent-*`

Use `git branch --list` with these patterns, then cross-reference against branches checked out in worktrees (`git worktree list --porcelain | grep "^branch "`). Show merged vs unmerged status.

```
=== Orphaned Branches ===
  Merged (safe to delete): 14
    worktree-agent-a25403ca, worktree-agent-a2564af2, ...
  Unmerged (need --force): 4
    agent-3-tmp, ...
```

### 1.5 Decision point

If `--dry-run`: print "Dry run complete. No changes made." and stop.

Otherwise, ask the user for confirmation:
> "Ready to recycle N worktrees and delete M orphaned branches. Proceed?"

## Phase 2: Recycle Active Worktrees

For each non-main worktree, run these steps sequentially:

### 2.1 Auto-commit dirty changes

```bash
cd "$wt_path"
if [ "$(git status --short | wc -l)" -gt 0 ]; then
  git add -A
  git commit -m "wip: auto-save before worktree recycle"
  echo "  Auto-committed dirty changes"
fi
```

### 2.2 Push current branch to origin

```bash
cd "$wt_path"
current_branch=$(git branch --show-current)
if [ -n "$current_branch" ]; then
  git push origin "$current_branch" --set-upstream 2>&1 || echo "  WARNING: push failed, work is committed locally"
fi
```

If the worktree is in detached HEAD state (no branch), skip the push.

### 2.3 Checkout new branch off origin/develop

```bash
cd "$wt_path"
# Delete old local branch with this name if it exists and isn't checked out elsewhere
git branch -D "$new_branch" 2>/dev/null || true
git checkout -b "$new_branch" origin/develop
```

If `git branch -D` fails because the branch is checked out in another worktree, append a timestamp: `agent-N-$(date +%s)`.

Report: `  platform-agent-2: fix/build-deps-caching → agent-2 (pushed, 2 files auto-committed)`

## Phase 3: Clean Orphaned Branches

### 3.1 Delete merged orphans

```bash
for branch in $(git branch --merged develop --list 'worktree-agent-*' 'agent-*-tmp' 'develop-agent-*' | tr -d ' '); do
  # Skip if checked out in a worktree
  if git worktree list --porcelain | grep -q "branch refs/heads/$branch"; then
    continue
  fi
  git branch -d "$branch"
done
```

### 3.2 Handle unmerged orphans

If `--force`: `git branch -D "$branch"` for each unmerged orphan.
Otherwise: list them with "SKIP (unmerged, use --force)".

### 3.3 Prune remote tracking

```bash
git remote prune origin
```

## Phase 4: Final Summary

Print a summary of everything done:

```
=== Worktree Recycle Complete ===

Recycled:
  platform-agent-2: fix/build-deps-caching → agent-2 (pushed, auto-committed)
  platform-agent-3: chore/app-readme-cleanup → agent-3 (pushed, clean)

Orphaned branches deleted: 14 merged, 0 force-deleted
Orphaned branches skipped: 4 unmerged

All worktrees are now on fresh branches off origin/develop.
```

## Safety

- NEVER force-push or rewrite history
- NEVER delete worktree directories (only recycle branches)
- NEVER run `git worktree remove` — this skill does not remove worktrees
- NEVER run `git worktree prune` — missing directories may be temporary
- NEVER run `rm -rf`, `rm -r`, or `rmdir` on any worktree path
- NEVER touch the main repo worktree
- Always push before resetting to preserve work
- Always show summary and get confirmation first
- Unmerged orphan branches are protected unless `--force` is explicit
- If a worktree directory is missing, STOP and report to the user — do not auto-fix
