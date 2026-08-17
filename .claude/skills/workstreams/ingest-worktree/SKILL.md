---
name: ingest-worktree
description: Land a dirty working tree correctly - survey it, group every change by concern, write conventional-commit messages, and ship each concern as its own branch + PR (never one mixed blob). It HOLDS machine-local/ephemeral churn (theme-switch output, caches) and scans untracked files for secrets before they go public. It also checks the checkout is not stale before landing, because a tree edited against an old base can silently revert work that has since landed on the default branch. Use when the user says "get my hanging changes in", "land the worktree", "ingest the worktree", "clean up my git status into PRs", "ship the dotfiles", or "what is all this uncommitted stuff". Branch-first off the default branch. Differs from sc:git (single commit helper), my:pr-merge-flow (drives ONE existing PR), and ingest-prs (drains the open-PR queue on the FORGE - use that one when the user points at open PRs rather than at their own dirty tree). Do NOT `git add -A` a mixed tree, and do NOT commit theme/ephemeral churn or unscanned untracked files.
metadata:
  category: workstreams
  tags: [git, pull-requests, landing]
  reviewed: "2026-08-17"
---

# ingest-worktree

Land a dirty working tree into landed, reviewable units - one concern per PR, nothing mixed, nothing unsafe.

```
dirty tree ->  survey  ->  classify by concern  ->  HOLD churn/secrets  ->  land each concern as a PR
                                                          |
                                              (theme state, caches, keys) -> surfaced, not committed
```

**Pointed at the forge instead?** "we have N open PRs", "land the open PRs", "should I close all these" -> use **`ingest-prs`**. Draining an existing queue needs a per-PR definition table (what / who / why / where / tier / blocker) before any close-or-land verdict, which is a different shape of work than fanning a dirty tree out.

## 1. Survey
```bash
git branch --show-current; git remote -v
git status --short
git diff --stat
git ls-files --others --exclude-standard      # untracked
```
Read the diffs. Never trust filenames alone; classify by what changed.

**Then check the base, before planning anything.** A dirty tree says nothing about how old it is:
```bash
git fetch origin
git rev-list --count HEAD..origin/main        # how far behind
git log --oneline -1 $(git merge-base HEAD origin/main)
```
If that count is not 0, every pending edit was authored against a file that may since have changed, and reapplying it blind REVERTS whatever landed in between. For each modified file, compare against the current base rather than the diff you have:
```bash
git cat-file -e origin/main:<path> || echo "path no longer exists on main - find where it moved"
diff <(git show origin/main:<path>) <path>
```
Three outcomes, and they are different concerns: **already landed** (drop it - do not re-land a duplicate), **landed differently / better** (keep the base version, re-derive only your delta on top), **still absent** (land it, but at the path the base uses now - a reorganized tree makes the old path a dead end that git will happily commit). Also check an unpushed local branch's PR state: a CLOSED-unmerged PR either means the work was superseded elsewhere or it is orphaned, and only reading the base settles which.

## 2. Classify by concern
Bucket every changed file into exactly one concern (a file may only live in one PR, or branches collide on merge). Typical dotfiles concerns: a named feature/skill, lab/agent tooling, tracker/ticket, editor (nvim), shell/prompt, a new service. Write one conventional-commit subject per bucket (`feat(scope):`, `fix(scope):`, `chore(scope):` - match the repo's existing `git log` style).

**Before assigning, run the two safety filters:**

- **Ephemeral / machine-local churn -> HOLD.** Anything a timer, daemon, or generator writes is not a hand-authored change and usually differs per machine. Tell-tales: a file whose git history shows commits like "applied by X.timer"; a comment saying another tool "sed-rewrites" it; a working-tree diff that is only a color-palette swap (theme-switch). Examples in this repo: `.config/kitty/current-theme.conf`, `.config/starship.toml` colors, the nvim `colorscheme` line + lualine/neo-tree highlight colors, `lazygit` theme colors. Do NOT commit these - the theme-switch timers own them. Surface them in the report so the user decides.
- **Secret scan on untracked -> BLOCK until cleared.** Before committing any untracked file, read it. Reject real keys/tokens/passwords. Confirm a `.gitignore` excludes runtime/auth state (keypairs, sqlite, `data/`). A compose/README that merely *mentions* "key" (e.g. rustdesk `-k _`) is fine; an actual private key value is not.

## 3. Plan
Show the user the buckets: for each, the concern, the commit subject, the file list, and PR-vs-main. List the HELD items separately with the reason.

Then **land them - do not stop here for an OK.** Invoking this skill IS the authorization to push and merge; asking again is the failure mode it exists to fix (work that is reviewed, green and correct still sitting in the tree tomorrow). Stop and ask only for the two things a bucket list cannot settle: an untracked file whose secret scan is not clearly clean, and a HELD item you think should ship anyway.

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

## Triggers
- Manual: `/ingest-worktree` (or the phrases in the description). Typically at the end of a work batch or when `git status` has sprawled.
- Pairs with `wind-down` (land before teardown) and `gh-workflows` (PR mechanics). Hand off to `ingest-prs` when the queue on the forge is the problem, and to `my:pr-merge-flow` to babysit one PR deeply.

## Boundaries
- Never `git add -A`/`git commit -am` a mixed tree; one concern per commit, one file per PR.
- Never commit ephemeral/machine-local churn or unscanned untracked files - HOLD and surface.
- Branch-first off the default branch, then push and merge without re-confirming; the skill invocation is the authorization. The two exceptions are an unclear secret scan and a HELD item you want to ship anyway.
- Never reapply a stale edit blind. If the checkout is behind the default branch, re-derive each change against the CURRENT file before committing - see Survey.
- It lands changes; it does not author new feature work.
