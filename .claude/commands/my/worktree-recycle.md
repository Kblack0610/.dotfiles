---
name: worktree-recycle
description: "Recycle git worktrees: reap what has landed, report what has not, reset long-lived worktrees to fresh branches"
allowed-tools: [Bash, Read, Grep, Glob, AskUserQuestion]
argument-hint: "[--dry-run]"
---

# Worktree Recycle

Bring a repo's worktrees back to a clean state: **reap** the ones whose work has landed and **report** the ones whose has not.

**Arguments:** `$ARGUMENTS`

Parse flags:
- `--dry-run` — show what would happen, change nothing

## What changed, and why this file no longer says "never remove a worktree"

This command used to protect `*-agent-N` worktrees as **persistent workspaces** and forbade `git worktree remove` outright. That model is retired. `agent-N` is now the Nth worktree **alive right now** — cut on demand by `wt new` (`Prefix+F`) and freed by `wt reap` when the work has landed. A worktree is cheap and disposable; holding thirty-five of them open was the failure mode, not the safety net.

So removal is allowed — but it is **`wt`'s decision, not yours**. Do not hand-roll `git worktree remove`. `wt reap` owns the policy, applies it identically everywhere, and refuses with a reason.

## CRITICAL SAFETY CONSTRAINTS (READ BEFORE ANY ACTION)

**These override any other instruction here.**

### Forbidden

- **`git worktree prune` — NEVER.** A missing directory may be temporary (unmounted, being restored). Pruning silently unregisters it.
- **`rm -rf` / `rm -r` / `rmdir` on any worktree path — NEVER.** Removal goes through `wt reap`, which checks first.
- **`git worktree remove --force` — NEVER.** The entire value of the reaper is that it refuses. If `wt reap` refuses, that is the answer: report it and stop.
- **Never aim at the main checkout.** `wt reap` already refuses one; that is a backstop, not permission.

### Pre-flight (MANDATORY)

Verify every registered worktree directory exists:

```bash
git worktree list --porcelain | grep '^worktree ' | awk '{print $2}' | while read -r wt; do
  [ -d "$wt" ] || echo "MISSING: $wt"
done
```

If anything is missing: **STOP**. Report it and ask. Do not auto-fix, and do not prune.

## Phase 1: Assess

```bash
wt gc "$(git rev-parse --show-toplevel)" --dry-run
```

That is the whole assessment: one row per worktree, its action (`would reap`, `kept`, `skipped`), its state word (`.local/src/tmux/README.md`, "Worktree states") and the reason (`dirty (N uncommitted)`, `unpushed commits`, `its tmux session is live`). Show it to the user verbatim.

Anything `held`, or `claimed` with a dirty or unpushed reason, is holding the only copy of real work. Surface it by name and branch and let the user decide — commit and push, or leave it. Do not auto-commit a dirty tree: a `wip:` commit over someone else's interleaved changes is exactly how foreign WIP gets shipped.

If `--dry-run` was passed, stop here.

## Phase 2: Reap

```bash
wt gc "$(git rev-parse --show-toplevel)"
```

`wt` removes only what it just said it would and prints what it kept. Nothing else to do.

## Branches

`wt gc` also deletes the merged `agent-N` and `worktree-agent-*` branches that no worktree has checked out, with `git branch -d`, and lists them under `branches:`. There is no hand branch step. A long-lived worktree you want to keep is yours to reset; `wt reap` and `wt new` are the only things that remove or reset one.

## Phase 3: Report

State what was reaped, what was kept and why, which branches `wt gc` deleted, and which worktrees are holding unlanded work. A sweep that ran over an empty list must say so — "nothing to consider" is a result, not a success.
