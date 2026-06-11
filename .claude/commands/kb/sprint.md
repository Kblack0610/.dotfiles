---
name: sprint
description: Run a ticket batch through the kb pipeline — queue via kb-sprint-owner, dispatch kb-coordinator per ticket, monitor CI, merge, flip tickets Done. Internal machinery — prefer /captain as the user entry point
argument-hint: plan [epic|ids|from-captain] | run | resume | status
allowed-tools: Task, Bash, Read, Write, Edit, Grep, Glob
---

# kb:sprint — $ARGUMENTS

Batch dispatcher for the kb-* pipeline. Three roles, one blackboard:

| Role | Authority | Owns in the plan file |
|---|---|---|
| `kb-sprint-owner` agent (Sloane 🗂️) | decides WHAT, in what ORDER | `## Meta` + `## Queue` |
| **this command** (dispatcher, main session) | EXECUTES: kb-coordinator per ticket, CI monitor, merge, Done fallback | Status/PR/Result columns, `## Run log`, `## Blocks` |
| `sprint-overseer` skill+agent (Argus 👁️) | OBSERVES + NOTIFIES, never executes | `notified:` markers, `## Batch summary` |

The blackboard is `~/.agent/plans/{project}/sprint-{YYYY-MM-DD}.md`. `{project}`
resolves through `~/.dotfiles/.config/shared-hooks/project-map.json` — always the
canonical project name (e.g. `bnb-platform`), never the worktree basename.

**Operational model:** the dispatcher runs in the main session (it is
synchronously busy inside Task calls). The overseer runs in a **second
session** via `/loop 10m /sprint-overseer watch`, so it survives dispatcher
death — that's the point of its stall detection. `plan` prints the bootstrap
line to copy into the second session.

## Plan file schema

```markdown
# Sprint — {project} — {YYYY-MM-DD}

## Meta
- Repo: <abs path>
- Mode: sequential            # v2: parallel:N
- Source: <epic / ids / release-captain plan ref>
- Overseer: /loop 10m /sprint-overseer watch
- Started: <ISO ts, blank until `run`>

## Queue
| # | Ticket | Title | Pri | Lane | Conflicts | Rationale | Status | PR | Result |
|---|--------|-------|-----|------|-----------|-----------|--------|----|--------|

Status ∈ queued | in-progress | pr-open | merged | blocked | error | skipped

## Run log
(dispatcher appends timestamped lines; overseer appends `notified:` markers)

## Blocks
(kb-coordinator BLOCK/ERROR JSON verbatim per ticket + a "Needs:" line)

## Batch summary
(written by sprint-overseer `report`)
```

## Verb: `plan [epic|ids|from-captain]`

1. Resolve the repo (primary checkout or active worktree) and the canonical
   project name via project-map.
2. Invoke the `kb-sprint-owner` agent via Task with the caller's input
   (epic filter, explicit ticket IDs, and/or a fresh release-captain `plan`
   brief's next-work section). It reads the board + WIP state and writes the
   plan file with `## Queue` populated, all rows `queued`.
3. Print the queue table and ask the user to approve it. **The queue approval
   is the one human gate — after approval, `run` is autonomous.**
4. Print the overseer bootstrap line for a second session:
   `/loop 10m /sprint-overseer watch`

## Verb: `run`

Pre-flight: working tree must be clean and on `develop` (pull first); the
newest sprint file must have `queued` rows and an approved queue. Stamp
`Started:` in Meta. Then, for each `queued` row in order:

1. Mark the row `in-progress`; append a Run-log line.
2. Dispatch `kb-coordinator` via Task:
   > Ship <tracker> ticket `<id>`: **<title>**. First claim it per the kb
   > Phase-0 ticket step (MCP-first, `ticket claim <id>` fallback) and capture
   > the PR-body line (`TICKET_LINE`, e.g. `Vikunja: <id>`). Ticket body:
   > <body / acceptance criteria>. The PR body must include the captured
   > `TICKET_LINE` under a `## Ticket` section.
3. Parse the returned JSON (kb-coordinator's return contract):
   - `PASS` → record `pr_url`, mark `pr-open`, continue to step 4.
   - `BLOCK` / `ERROR` → record the JSON verbatim under `## Blocks` with a
     one-line `Needs:` note, mark the row `blocked`/`error`, append a Run-log
     line, **continue to the next ticket** — one block never wedges the batch.
4. **CI-monitor + merge (dispatcher-owned):** poll `gh pr checks <pr> ` at
   60–90s intervals. On required-checks green:
   `gh pr merge <pr> --squash --delete-branch`. On a red required check, make
   **one** `my:fix-ci`-shaped repair attempt (push fix to the PR branch,
   re-poll); if still red, mark `blocked` with the failing check in
   `## Blocks` and move on.
5. Verify the tracker's close-on-merge hook flipped the ticket Done within
   ~2 min (e.g. `vikunja-close-on-merge.yml`); if not, run
   `ticket done <id>` as the fallback. Mark the row `merged`, record `Result`,
   append a Run-log line.
6. `git checkout develop && git pull` so the next ticket builds on the merge.

After the last row: append a final Run-log line (`batch complete`) and tell
the user the overseer's `report` verb will write the summary — or run
`/sprint-overseer report` directly if no overseer loop is active.

**Notification carve-out:** this command calls `agent-notify` ONLY for its own
terminal abort (`agent-notify -t kb-sprint -p high "sprint aborted: <cause> —
resume with /kb:sprint resume"`), because a dying dispatcher cannot assume the
overseer loop is running. All routine voice (per-ticket merged/blocked, stall,
batch summary) belongs to the sprint-overseer — never duplicate it.

## Verb: `resume`

1. Find the newest `sprint-*.md` with non-terminal rows
   (`queued|in-progress|pr-open`).
2. Reconcile each non-terminal row against reality BEFORE acting:
   - branch exists? PR open (`gh pr view --json state,mergedAt`)? already
     merged? ticket already Done?
   - update the row to the true state, append a Run-log line
     (`resume: reconciled #N <old>→<new>`).
3. Rejoin the `run` loop at the correct step for the first non-terminal row
   (an orphaned `pr-open` row rejoins at step 4; an orphaned `in-progress`
   row with no branch/PR restarts at step 2).

Works from a completely fresh session — the plan file plus live `gh`/tracker
state is the entire resume contract.

## Verb: `status`

Print the queue table and the tail of the Run log. No notifications, no
writes. (For the notifying dashboard, use `/sprint-overseer status`.)

## Hard constraints

- Implementation PRs only. Never push release tags, never run `deploy.sh`,
  never touch the Vikunja `HUMAN:` line or GitHub approval issues — release
  execution stays with the user via `placemyparents-release`, release
  analysis with `release-captain`.
- Merging implementation PRs on required-green is in-scope (established
  doctrine: 60–90s polling, merge on required checks). A PR needing a human
  review approval that cannot be satisfied → mark `blocked`, surface the URL,
  move on. Never loop on merge attempts.
- One repair attempt per red CI, one block per ticket — no unbounded retries.

## v2 — parallel mode (documented, not yet built)

`Mode: parallel:N` in Meta. `run` claims worktrees from the persistent
`platform-agent-{2..6}` pool (prepped via `my:worktree-recycle`) and
dispatches up to N kb-coordinators concurrently, each Task prompt prefixed
with "work in `<worktree path>`". Constraints: rows sharing a `Conflicts`
group serialize; guarded-lane tickets always run alone. **The merge step
stays single-writer** — the dispatcher merges in completion order with a
develop-sync per PR to absorb cross-PR drift. Everything else (plan file
schema + `Worktree` column added, kb-coordinator contract, overseer,
kb-sprint-owner) is unchanged.

## Related

- `kb-sprint-owner` agent — queue builder (`plan` delegates to it)
- `kb-coordinator` agent — per-ticket pipeline + JSON return contract
- `sprint-overseer` skill — watchdog + single notification voice
- `release-captain` skill — `plan` next-work output feeds the queue; merged
  batches surface in its `status` automatically
- `~/.dotfiles/.local/bin/agent-notify` — abort-only here; routine voice is
  the overseer's
