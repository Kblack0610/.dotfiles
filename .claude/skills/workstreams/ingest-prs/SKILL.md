---
name: ingest-prs
description: Triage and land the open pull-request queue on the forge. Its FIRST and mandatory output is a definition table naming every open PR - number, title, author, age, head -> base, what it does, why it exists, where it lands, size, review tier, CI, conflict state, and a per-PR verdict (LAND / FIX-THEN-LAND / DRAFT / CLOSE / KEEP) - because you cannot decide what to close until every PR is defined. Only after that table is on screen may it propose merging, drafting, or closing anything. Use when the user says "what are all these open PRs", "define every open PR", "should I close all of these", "drain the PR queue", "land the open PRs", "why is this still open", "what's blocking these", or points at a list/screenshot of PRs. Also answers "what should be on my env branch" by checking which PR heads are already contained in it. Differs from pr-review (ONE PR, deep review + bot comments), my:pr-merge-flow (babysits ONE PR to merge), release-ingest (batch-lands WITH version/CHANGELOG/tag discipline for a release cut), and ingest-worktree (LOCAL dirty working tree, not the forge). Do NOT merge a conflicted or failing-CI PR, do NOT self-merge or --admin anything in the repo's human-approval tier, and NEVER `gh pr close --delete-branch` an unmerged PR.
metadata:
  category: workstreams
  tags: [git, pull-requests, triage]
  reviewed: "2026-08-17"
---

# ingest-prs

The open-PR queue is a work-in-progress ledger. When it grows past what one person can hold in their head it stops being a ledger and becomes noise, and the reflex is to select-all and close. That reflex is usually half right: most of the queue is dead, and one or two items in it are the fix the user is actively waiting on.

So this skill has one hard sequencing rule:

> **Define every PR before proposing any verdict.** No "close these, keep those" until the definition table below is on screen. Closing a PR the user needed, or keeping five that are superseded, both come from skipping this.

```
list -> DEFINE every PR (mandatory table) -> tier + blocker per PR -> verdict -> confirm -> execute -> report
                    |
        never skip to a verdict from a bare list
```

## 1. Collect, in as few calls as possible

One list call for the shape of the queue:

```bash
gh pr list --state open --limit 100 \
  --json number,title,author,createdAt,updatedAt,headRefName,baseRefName,isDraft,\
mergeable,mergeStateStatus,reviewDecision,additions,deletions,changedFiles
```

`mergeable`/`mergeStateStatus` read `UNKNOWN` right after a push; GitHub computes them lazily and `gh pr view <n>` forces the calculation.

Then ONE GraphQL call for every PR's file list, rather than a per-PR loop (a loop of `gh api --paginate` over a 10-PR queue is slow enough that users kill it):

```bash
gh api graphql -f query='
{ repository(owner:"OWNER", name:"REPO") {
    pullRequests(states:OPEN, first:50) { nodes {
      number
      files(first:100) { nodes { path } }
      commits(last:1) { nodes { commit { statusCheckRollup { state } } } }
    } } } }'
```

**The 100-file cap is real and it is a trap.** `gh pr view --json files` silently truncates at 100, so a protected path in file 101 vanishes and the PR gets mis-tiered. When `changedFiles > 100`, page the REST endpoint for that PR specifically:
`gh api repos/OWNER/REPO/pulls/<n>/files --paginate -q '.[].filename'`

For the "what / why" column, read the PR body, not the title. Repos with a review culture put the reason, the supersession history, and the verification in the body. Titles lie by omission.

## 2. The definition table (MANDATORY, emit this first)

One row per open PR, no exceptions, drafts included:

| Col | Content |
|---|---|
| **#** | PR number |
| **What** | One plain line: the behaviour change, not the title restated |
| **Who** | Author login. Flag when it is not the user - you may not close someone else's work on their behalf |
| **Age** | Days open, and days since last update. A PR updated today is alive; one untouched for two weeks is not |
| **Where** | `head -> base`, plus which environment that base actually deploys to |
| **Size** | `+adds/-dels`, N files. Note if over the automated reviewer's file limit (Copilot silently refuses ~300+, so its review can never arrive and the PR looks merely un-reviewed) |
| **Tier** | `HUMAN` or `self-merge`, decided by PATH from the repo's own policy - see step 3 |
| **CI** | green / red / none. `none` means YOU are the gate |
| **Blocker** | The ONE thing stopping it: conflict, red CI, review gate, draft, or a dependency on another PR |
| **Verdict** | LAND / FIX-THEN-LAND / DRAFT / CLOSE / KEEP, with the reason in a few words |

Two columns to add when the repo has per-developer environment branches: **on-env** (is this PR's head already contained in `<handle>dev`, i.e. already being tested) and **needed-by** (a symptom the user is chasing that this PR fixes). The second is what stops a bulk close from throwing away the fix for the bug they are angry about.

## 3. Tier by PATH, from the repo's own policy

Read the repo's `AGENTS.md` / `CLAUDE.md` / `CONTRIBUTING.md` review policy and the `AGENTS.local.md` overlay if present. Most repos with a real policy gate a list of paths behind mandatory human approval, typically infra/Terraform, production deploy manifests, CI workflow definitions, the deploy/release scripts, and any artifact whose rollback is per-device rather than a redeploy.

Decide the tier from the PR's actual changed-file list, never from what the change feels like. A pure-docs PR is in the tier if it touches a protected path. **An agent must not self-merge or `--admin` merge anything in the human tier**, no matter how green CI is, whose PR it is, or how long it has waited; a local per-developer rules file may tighten that but never loosen it.

## 4. Verdicts, and what closing actually costs

Closing is cheaper than it feels and more expensive than it looks:

- **Cheap:** the branch survives a close. The commits survive. The PR can be reopened. Nothing is destroyed as long as you do not delete the branch.
- **Expensive:** you lose the review state (an earned approval does not come back), the bot review has to run again, the inline review threads stop being the record, and the reason it existed evaporates unless someone writes it down.

So the rules:

- **Never `gh pr close --delete-branch` an unmerged PR.** That orphans the only copy of the work (recoverable only via `git log -g`, and not at all once the remote branch is gone).
- **Write the disposition into the close comment.** One or two lines: what supersedes it, what is NOT lost, whether the branch is kept. A closed PR with a bare close is unrecoverable knowledge; a closed PR with "superseded by #N, the runtime half is filed as TICKET, branch kept" stays useful a month later.
- **An APPROVED + green PR is never a close candidate** on conflict alone. That approval is the scarce resource in the queue; rebase it and land it.
- **A PR that fixes a bug the user is currently chasing is never a bulk-close candidate**, even if it is old and conflicted.
- **DRAFT rather than CLOSE** when the work is still wanted but not ready. That is what keeps "open" meaning "ready for review", which is the whole point of the queue.
- **Do not close another author's PR** without their say-so; hand it back instead.

## 5. Confirm, then execute

Show the table plus a grouped plan (LAND these N, FIX-THEN-LAND these N, DRAFT these N, CLOSE these N with the disposition line each) and get an explicit OK. Merging and closing are both visible writes, and a close notifies the author.

```bash
# land (match the repo's convention: check git log for "Merge pull request" vs a flat squashed history)
gh pr merge <n> --squash --delete-branch     # --delete-branch is safe ONLY because it merged

# hold work that is not ready, without losing it
gh pr ready <n> --undo

# close with the disposition recorded, branch kept
gh pr comment <n> --body "Closing: superseded by #NNN. <what is not lost>. Branch kept, not deleted."
gh pr close <n>
```

Land in dependency order: disjoint file sets merge in any order, overlapping ones mean land one and re-check the rest, because the base moved. After a batch, sync local and prune with `git branch -d` (never `-D` - the refusal is the safety net).

## 6. Report

Per PR: landed (link + state), drafted, closed (with the disposition), or held (with the one blocker). Then: the new base SHA, branches pruned, and - the part that matters most - **what is still blocked on a human**, named explicitly. A queue that is blocked on review does not get better by closing PRs, and saying so is the useful output.

## Triggers

- Manual: `/ingest-prs`, or the phrases in the description. Typically when the queue has outgrown the user's head, before a release cut, or when a user is angry that a known fix has not shipped.
- Pairs with `pr-review` (go deep on one row of the table), `gh-workflows` (PR mechanics), `release-ingest` (when the batch is a release and needs version/CHANGELOG/tag discipline), and `ingest-worktree` (the local-tree mirror of this skill).

## Boundaries

- Never emit a verdict before the definition table.
- Never merge a CONFLICTING/DIRTY or failing-CI PR; resolve first.
- Never self-merge or `--admin` merge a PR in the repo's human-approval tier, and never document a bypass for it.
- Never `--delete-branch` an unmerged PR; never close another author's PR unasked; never close without recording the disposition.
- It triages and lands existing PRs; it does not author new feature work and does not fix a PR's code beyond resolving a merge conflict.
