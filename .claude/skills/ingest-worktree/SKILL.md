---
name: ingest-worktree
description: Land a pile of hanging dotfiles (or any repo's) working-tree changes correctly - survey the dirty tree, group every change by concern, write conventional-commit messages, and ship each concern as its own branch + PR (never one mixed blob). Crucially it HOLDS what should not be committed - machine-local/ephemeral churn (theme-switch output, current-theme files, generated caches) and scans untracked files for secrets before they go public - and surfaces those instead of committing them. Use when the user says "get my hanging changes in", "land the worktree", "commit and PR all this", "ingest the worktree", "clean up my git status into PRs", "ship the dotfiles", or when `git status` has piled up across many concerns. Branch-first off the default branch. Differs from sc:git (single commit helper) and my:pr-merge-flow (drives one existing PR) - this one FANS a dirty tree OUT into multiple correctly-scoped PRs. Do NOT blindly `git add -A` a mixed tree, and do NOT commit theme/ephemeral churn or unscanned untracked files.
---

# ingest-worktree

Turn a messy `git status` into correctly-scoped PRs. The name = ingest the working tree into landed, reviewable units. One concern per branch/PR; nothing mixed; nothing unsafe.

```
dirty tree ->  survey  ->  classify by concern  ->  HOLD churn/secrets  ->  land each concern as a PR
                                                          |
                                              (theme state, caches, keys) -> surfaced, not committed
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

## Triggers
- Manual: `/ingest-worktree` (or the phrases in the description). Typically at end of a work batch or when `git status` has sprawled.
- Pairs with `wind-down` (land before teardown) and `gh-workflows` (PR mechanics).

## Boundaries
- Never `git add -A`/`git commit -am` a mixed tree; one concern per commit, one file per PR.
- Never commit ephemeral/machine-local churn or unscanned untracked files - HOLD and surface.
- Branch-first off the default branch; confirm before the first push.
- It lands changes; it does not author new feature work.
