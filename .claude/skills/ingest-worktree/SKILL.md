---
name: ingest-worktree
description: Land work correctly, two modes. LOCAL mode (default) ingests a dirty working tree - survey it, group every change by concern, write conventional-commit messages, and ship each concern as its own branch + PR (never one mixed blob); it HOLDS machine-local/ephemeral churn (theme-switch output, caches) and scans untracked files for secrets before they go public. REMOTE mode drains the open-PR queue - list every open PR, check each for mergeable/CI/conflicts, review the diff (the gate when no CI runs), then land the safe ones and sync local main. Use LOCAL when the user says "get my hanging changes in", "land the worktree", "ingest the worktree", "clean up my git status into PRs", "ship the dotfiles"; use REMOTE when the user says "land the open PRs", "drain the PR queue", "get our open PRs in", "we have N open PRs", or invokes this skill pointing at the remote rather than the local tree. Branch-first off the default branch. Differs from sc:git (single commit helper) and my:pr-merge-flow (drives ONE existing PR) - this FANS a dirty tree OUT into scoped PRs (local) or DRAINS many open PRs at once (remote). Do NOT `git add -A` a mixed tree, do NOT commit theme/ephemeral churn or unscanned untracked files, and do NOT merge a conflicted / failing-CI PR or `--delete-branch` an unmerged one.
---

# ingest-worktree

Land work into landed, reviewable units — one concern per PR, nothing mixed, nothing unsafe. Two modes:

- **LOCAL (default)** — ingest a dirty working tree, fanning it OUT into scoped PRs. Sections 1-5.
- **REMOTE** — drain the open-PR queue that already exists on the forge. "Mode: REMOTE" below.

Pick by what the user points at: their `git status` (local) vs "we have N open PRs / land them" (remote).

```
LOCAL:  dirty tree ->  survey  ->  classify by concern  ->  HOLD churn/secrets  ->  land each concern as a PR
                                                                 |
                                                     (theme state, caches, keys) -> surfaced, not committed

REMOTE: open PRs   ->  list + status  ->  triage (mergeable/CI/conflict/draft)  ->  review diff  ->  land safe ones -> sync main
```

## 1. Survey
```bash
git branch --show-current; git remote -v
git status --short
git diff --stat
git ls-files --others --exclude-standard      # untracked
```
Read the diffs. Never trust filenames alone; classify by what changed.

## 2. Classify by concern
Bucket every changed file into exactly one concern (a file may only live in one PR, or branches collide on merge). Typical dotfiles concerns: a named feature/skill, lab/agent tooling, tracker/ticket, editor (nvim), shell/prompt, a new service. Write one conventional-commit subject per bucket (`feat(scope):`, `fix(scope):`, `chore(scope):` - match the repo's existing `git log` style).

**Before assigning, run the two safety filters:**

- **Ephemeral / machine-local churn -> HOLD.** Anything a timer, daemon, or generator writes is not a hand-authored change and usually differs per machine. Tell-tales: a file whose git history shows commits like "applied by X.timer"; a comment saying another tool "sed-rewrites" it; a working-tree diff that is only a color-palette swap (theme-switch). Examples in this repo: `.config/kitty/current-theme.conf`, `.config/starship.toml` colors, the nvim `colorscheme` line + lualine/neo-tree highlight colors, `lazygit` theme colors. Do NOT commit these - the theme-switch timers own them. Surface them in the report so the user decides.
- **Secret scan on untracked -> BLOCK until cleared.** Before committing any untracked file, read it. Reject real keys/tokens/passwords. Confirm a `.gitignore` excludes runtime/auth state (keypairs, sqlite, `data/`). A compose/README that merely *mentions* "key" (e.g. rustdesk `-k _`) is fine; an actual private key value is not.

## 3. Plan + confirm
Show the user the buckets: for each, the concern, the commit subject, the file list, and PR-vs-main. List the HELD items separately with the reason. Get an OK before any push (a push/PR is a visible write).

## 4. Land each concern
Default: branch-first off the default branch, one PR per concern, merged as you go so the tree stays functional (each merge lands before the next branch is cut, so no committed file ever vanishes from the working tree and live symlinked tooling keeps working). Per bucket:
```bash
base=$(git branch --show-current)                 # usually main
git switch -c pr/<concern> "$base"                # carries the dirty tree
git add <exact paths for this concern>            # NEVER add -A
git commit -m "<type(scope): subject>"
git push -u origin pr/<concern>
gh pr create --fill --title "<subject>" --body "<what + why>"
gh pr merge --squash --delete-branch              # "get it in"; omit to leave open for review
git switch "$base" && git pull --ff-only          # main now has this concern; remaining buckets stay dirty
```
If the user chose "leave PRs open," skip the merge + pull and just move to the next branch off `base` (independent file sets => no conflicts). Use the `gh-workflows` skill conventions for PR bodies.

## 5. Report
Per concern: the PR link + merge state. Then the HELD items and why (so nothing is silently dropped - the churn is deferred to its timer; secrets need the user).

## Mode: REMOTE (drain the open-PR queue)

When the user points at the forge ("we have N open PRs", "land the open PRs", "drain the queue") rather than the local tree. Sections 1-5 above are the LOCAL mode; this is its mirror for PRs that already exist.

### R1. List + status
```bash
gh pr list --state open --json number,title,headRefName,baseRefName,isDraft,mergeable,mergeStateStatus,reviewDecision
```
`mergeable`/`mergeStateStatus` often read `UNKNOWN` right after a push — GitHub computes them lazily. Viewing a PR forces the calc:
```bash
gh pr view <n> --json number,title,mergeable,mergeStateStatus,statusCheckRollup,files
```
Reconcile the count with reality: a PR you JUST merged is gone from the list; a PR you just opened may not be counted yet.

### R2. Triage each PR
Bucket by landability. Never merge blind — the diff review IS the gate on a repo with no CI.
- **MERGEABLE / CLEAN + green (or no CI configured)** -> land. `CI:none` means no checks run, so YOU are the check: `gh pr diff <n>` and read it.
- **CONFLICTING / DIRTY** -> HOLD (or rebase the branch onto the base first); do not force it.
- **failing CI (`statusCheckRollup` has failure)** -> HOLD; fix or hand back.
- **draft** -> skip.
- **needs review / `reviewDecision: REVIEW_REQUIRED`** -> respect it unless the user owns the repo and waives it.
Check file sets across the PRs you'll land: disjoint files merge in any order; overlapping files mean land one, then re-check the others' mergeability.

### R3. Confirm + land
Show the queue (per PR: number, title, mergeable/CI, the one-line what, land-vs-hold) and get an OK — merging is a visible write, and you may be landing PRs you did not author. Then land each, matching the repo's merge convention (check `git log`: "Merge pull request #NN" => merge commits; a flat history => squash):
```bash
gh pr merge <n> --merge --delete-branch      # or --squash to match a squash repo
```
`--delete-branch` is safe here because the branch is MERGED. NEVER `gh pr close --delete-branch` an UNMERGED PR — it orphans the only copy of that work (recover via `git log -g`).

### R4. Sync local
The merges advanced the remote base; bring local level and prune:
```bash
git stash push -- <machine-local churn>       # e.g. .config/nvim/lazy-lock.json, if dirty
git switch main && git pull --ff-only
git branch -d <merged-local-branches>          # -d (not -D): refuses if not merged, a safety net
git stash pop
```

### R5. Report
Per PR: landed (link + merge state) or HELD (why — conflict, red CI, draft, review gate). Then the synced main SHA and any branches pruned.

## Triggers
- Manual: `/ingest-worktree` (or the phrases in the description). LOCAL typically at end of a work batch or when `git status` has sprawled; REMOTE when open PRs have piled up.
- Pairs with `wind-down` (land before teardown) and `gh-workflows` (PR mechanics). REMOTE overlaps `my:pr-merge-flow` (which drives ONE PR deeply) — use this to drain MANY at once, that to babysit one.

## Boundaries
- Never `git add -A`/`git commit -am` a mixed tree; one concern per commit, one file per PR.
- Never commit ephemeral/machine-local churn or unscanned untracked files - HOLD and surface.
- Branch-first off the default branch; confirm before the first push (LOCAL) or first merge (REMOTE).
- REMOTE: never merge a CONFLICTING/DIRTY or failing-CI PR without resolving first; never `--delete-branch` an UNMERGED PR (it orphans the work); read every diff before merging when no CI gates it.
- It lands changes; it does not author new feature work.
