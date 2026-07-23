---
name: dotfiles-land
description: Land a dotfiles change that spans the TWO-repo public/private split correctly - `~/.dotfiles` (public GitHub `Kblack0610/.dotfiles`) + `~/.dotfiles-private` (private overlay, stowed alongside). Use whenever you edit anything under `~/.dotfiles` and need to commit/PR/merge it, ESPECIALLY when a file turns out to be gitignored in the public repo (it lives in the private overlay). It tells you which repo each file belongs to (filesystem-decidable, never ask the user), branches + PRs each side separately (a cross-repo change = two PRs, normal), uses a worktree to avoid disturbing an unrelated dirty branch in the private repo, and merges both. Do NOT commit infra/secret-bearing files to the public repo, do NOT ask the user "which repo does this go in" (grep decides), and do NOT mix both repos' changes into one branch. Differs from ingest-worktree (generic dirty-tree fan-out / PR-queue drain) - this one encodes the SPECIFIC dotfiles two-repo topology and the public/private classification rule.
---

# dotfiles-land

Land a change to the dotfiles across the two-repo split without asking obvious questions. The
answer to "which repo?" is always decidable from the filesystem - never an AskUserQuestion.

## The topology (load-bearing)

| Repo | Path | Remote | Default | Holds |
|---|---|---|---|---|
| PUBLIC | `~/.dotfiles` | `git@github.com:Kblack0610/.dotfiles.git` | `main` | generic, shareable config |
| PRIVATE overlay | `~/.dotfiles-private` | `git@github.com:Kblack0610/.dotfiles-private.git` | `main` | anything referencing internal infra |

- Both are stowed onto `$HOME` (`stow --no-folding .`), so their trees overlap. A runtime file
  like `~/.local/bin/notes-sync` is a stow symlink into ONE of the two repos' working copies.
- The public repo **gitignores** the private-owned files (explicit blocklist in
  `~/.dotfiles/.gitignore`, ~lines 214-230) so they don't double-track. A physical copy may still
  sit in `~/.dotfiles/.local/bin/` (the deployed mirror) - it is gitignored there and TRACKED in
  `~/.dotfiles-private`.
- The public repo runs a **hostname sanitizer** on commit (real internal hostnames are redacted to
  `*.example.internal`). Never assume real hostnames survive in public-tracked files - and never
  hand-write a real internal hostname into a public file (the pre-commit secret scanner blocks it).

## Step 1 - classify every changed/new file (no user input)

For each path you touched:

```bash
git -C ~/.dotfiles check-ignore -v <path>
```

- **Prints a rule** -> file is PRIVATE. Its tracked source is `~/.dotfiles-private/<same relative path>`.
- **Prints nothing** -> file is PUBLIC. Track it in `~/.dotfiles`.

For a NEW file, also grep its content - a match means PRIVATE regardless of the ignore list.
Set `DOMAIN` to your internal domain (the one the sanitizer redacts) so the literal never lands in
a public file:

```bash
DOMAIN='<your-internal-domain>'   # e.g. the LAN/VPN domain the sanitizer rewrites
grep -nE "$DOMAIN|mosquitto|ntfy|nas\.|192\.168|10\.|/\.notes|SOPS|age1|BEGIN [A-Z ]*PRIVATE KEY" <path>
```

Clean + not-ignored -> PUBLIC. Any hit -> PRIVATE (add it to the public `.gitignore` blocklist so
the deployed mirror stays ignored, and track the source in the private repo). Precedent: generic
`notes-termux-bootstrap`/`journal-create`/`notes-mobile` are public; infra-bearing
`notes-bootstrap`/`notes-sync`/`notes-watch` are private.

## Step 2 - a cross-repo change is TWO PRs

Split your files into a public set and a private set. Each set = its own branch + PR in its own
repo. This is expected; do not try to force one PR, and do not ask whether to split.

### Public side (`~/.dotfiles`)

Branch off `main`, stage ONLY your files (never `git add -A` - the tree carries unrelated churn
like `waybar/style.css`, `android-suite`), commit (conventional), push, PR.

### Private side (`~/.dotfiles-private`)

If the private repo is clean on `main`: branch, edit, commit, push, PR as normal.

If it is on an **unrelated dirty branch** (common), do NOT stash/switch - use a worktree so that
branch is never touched:

```bash
cd ~/.dotfiles-private && git fetch -q origin
WT="$SCRATCH/dotfiles-private-<slug>"          # scratchpad dir, not /tmp
git worktree add -b feat/<slug> "$WT" origin/main
# apply the change in $WT (a private file's pre-edit content == its public mirror, so a
# `cp` of the already-edited public mirror yields exactly your intended hunks - verify with diff)
diff "$WT/<path>" ~/.dotfiles/<path>           # should show ONLY your changes
cp ~/.dotfiles/<path> "$WT/<path>"
( cd "$WT" && bash -n <script> && git add <path> && git commit -m '...' && git push -u origin feat/<slug> )
gh pr create -R Kblack0610/.dotfiles-private ...
```

## Step 3 - merge both, then clean up

The user saying "land it" / "merge these" is durable authorization for the whole task - merge both
without re-confirming. Squash-merge (repo convention: recent history is `... (#NN)` squashes).

```bash
gh pr merge <public#>  --squash --delete-branch -R Kblack0610/.dotfiles
gh pr merge <private#> --squash --delete-branch -R Kblack0610/.dotfiles-private
gh pr view <#> --json state -q .state          # confirm MERGED, don't assume
```

Cleanup: `git worktree remove --force "$WT"`; delete local feature branches; on each repo
`git fetch` THEN `git checkout main && git merge --ff-only origin/main` (fetch first - `gh` merges
server-side so the local ref is stale; skipping the fetch silently reverts the tree). Leave the
private repo's unrelated dirty branch exactly as you found it (a worktree never disturbs it).

## Guardrails

- Never commit an infra/secret-bearing file to the public repo. When unsure, grep (Step 1) - don't ask.
- Never `git add -A` a dotfiles tree; stage explicit paths.
- Never ask the user which repo a file belongs to - the filesystem answers it.
- Never `--delete-branch` an unmerged PR; never merge a conflicted / failing-CI PR.
