---
name: sprint
description: >-
  Run a project sprint on the notes board: lock one for N hours, check it, take a mid-sprint ask, read the cut score. Use for "set up a sprint", "is the sprint set up", "lock a sprint". Fix or re-send a cut: release.
metadata:
  category: workstreams
  tags: [sprint, release-window, notes, board]
  system: [dispatch]
  reviewed: "2026-11-21"
---

# Sprint

A project's sprint is its open version's release window: the rows it commits to, the only lane new asks get in by, and the score at the cut. The rules live in `~/.local/src/docs/stages.md`, "Release windows"; this skill is the commands that run them, so a session does not have to dig them out of notes-cli.

## Scope and triggers

- When the human asks whether a project has a sprint, or to set one up, shorten one or lock one for a number of hours.
- When the human asks why a row the lock left out (it waited, or did not fit) has not started: it ranks as the sprint's already, so look at its gate (step 4).
- When a new ask arrives mid-sprint and has to go in now, or wait for the next version.
- When a sprint's cut time has passed and the human asks why nothing moved.
- When the human wants a window that stays open and follows the sprint to its cut: that is `/coordinate sprint <project>` (`coordinate`, step 2).

Not for fixing or re-sending a release the system cut (builds, Steam upload, the default click): that is `release`; no session cuts one. Not for choosing which epics a version holds: `release-coordinator`. Not for board hygiene: `board-cleanup`.

## Where a sprint lives

- The snapshot is the `## Committed` section of the window's own file, `<project>/sprints/<vX.Y.Z>.md`; `notes projects --sprints <project> [--json]` lists the scored past windows, and `--version vX.Y.Z --json` adds one sprint's rows with their outcomes. The head line carries `opened=`, `due=`, and for a locked sprint `locked=` and `cut=`.
- Only a `#prio/focus` project runs sprints (`stages.md`, "Release windows"), and a focus ends on its `Focus until:`. Locking a sprint (`--commit --hours`) on a focus project moves that end out to the sprint's cut, so the freeze lasts the sprint; it never puts a project on focus. `notes board --json` lists its open window, and the next one queued behind it, under `.sprints`: `project`, `profile`, `version`, `committed`, `done`, `carried`, `opened`, `locked`, `cut`, `due`, `remaining_weight`, `rate_per_hour`, `tasks`, `uncommitted`, `queued`, `start`. Projects > Board shows the same rows in its Sprints table.
- A project with no entry there has no sprint: either it is not focus (its window, if any, still scores its cut and sets its state word) or it has no window (state `flow`, `stages.md`, "Project state"). To give a project a sprint, the human makes it focus first: `notes projects --prio <project> --set focus`.
- A project name resolves across profiles, so `--profile` is not needed.

## Steps

1. **Read the state first.** Check the project is focus; if `notes projects --prio <project>` does not print `focus`, it has no sprint to read or lock, so ask the human whether to make it focus before any step below.

   ```bash
   notes projects --prio <project>
   notes board --json | jq '.sprints[] | select(.project=="<project>") | del(.tasks)'
   ```

   Report what is there: the version, done of committed, the cut, and what the projected finish (`remaining_weight` over `rate_per_hour`) says about making it.

2. **Put the rows on the open version.** A lock takes the open version's rows (the sheet's `Version:` line): untagged rows and rows tagged at or below it. Rows aimed at a later `#vX.Y.Z` stay out. If the human wants those in, retag only them to the open version first, and say so in the report. Moving a row into the open version is open to any session. Once the window has a snapshot, a row it holds is frozen: notes-cli refuses a session, queue item or runner that moves it out (`move --to`, `demote`, `move --project`) or changes its priority (`stages.md`, "Release windows", Frozen rows).

3. **Lock the sprint.**

   ```bash
   notes projects --commit <project> --hours <h>
   ```

   `--hours` runs from one minute up to 720 hours. The command prints the rows committed, the capacity they filled, how many rows the earlier snapshot held, and the pinned rows left out. What it does:
   - The capacity is what the agent lane shipped over its budget window, scaled to `h` hours.
   - Rows fill it in this order: `#urgent`, then in progress, then `#requested`, then the rest, smallest first within each. A row too heavy for what is left is skipped.
   - A row that cannot land by the cut is left out: one behind `#after/<id>` of a row still open, or one held by an `#at/` gate that opens at or after the cut or cannot be read (a malformed `#at/9pm` keeps a row out).
   - The human lane commits nothing, because it has no measured pace.
   - A session runs it only on a version with no snapshot yet. Replacing a snapshot is a relock, which only the human can run from their own terminal; nothing waits on one (step 4). Every roll writes the next version's snapshot, so a rolled open version is usually already locked; a session sets up the next sprint by queueing it (step 7).
   - A lock that would commit no rows is refused, and the earlier snapshot stays.

   `--commit <project>` without `--hours` only records a window that opened with no snapshot, due on the cadence day. It never replaces one.

4. **Rows the lock left out move on their own.** The snapshot is only the score; dispatch ranks the rows it left out too, and a row that waited starts once its wait clears (`stages.md`, "Release windows", Flow). Do not ask the human to relock so that a row gets in. A relock is optional: the human runs one only to change what the score counts.

5. **Mid-sprint asks.** In a `#prio/focus` project with a snapshot, a new row goes to the next patch version unless it is an interrupt. An interrupt is a row tagged `#interrupt` or `#urgent`, or one aimed at the open version by hand; who files it does not count, the human included, so tag a mid-sprint ask `#interrupt` when it must join the open window; an `#urgent` row still waiting at the window's end goes to the next window at `#high` instead, unless aimed at the open one. Interrupts join the open window, tagged `#interrupt`, and the cut counts them as `interrupted`. Do not ask for a relock just to fit one ask in: an interrupt already gets in. A row already in the sprint stays there until the cut carries it. Close it with proof or drop it with a why; never move it out or change its priority.

6. **The cut.** `cut=` is when the sprint is due. At that time the release-cut lane cuts at the newest green full Tests run, and no open row holds it, `#urgent` included. When a cut has passed and nothing moved, read the lane's `~/.local/state/agentctl/release-window.stdout.log`: the usual cause is no green full run, or a failed cut run, which retries only at a newer green run. Passing the cut time rolls nothing by itself: the board keeps the sprint listed, showing its past cut, until the version rolls. The version itself moves on:
   - For a project its git tag owns, when the release tag ships. `agentctl-wave-roll` then rolls the sheet and carries the open rows.
   - For a sheet-counter project, when `agentctl-wave-roll` cuts it after its cadence has passed with done rows.

   The roll writes the score (committed, delivered, carried, dropped, interrupted) as `## Score` in the window's `sprints/` file; the frozen version note keeps a `Sprint:` link. For a tag-owned project, `notes-roll` by hand refuses to freeze a version no tag ships. That refusal is correct: put the rows on the open version (step 2) instead of forcing a roll.

7. **Queued sprints.** Any number chain behind the open one. Aim the rows at the version first (`notes ptask <p> move <id> --to vX.Y.Z`), then `notes projects --commit <p> --hours <h> --queue` locks the patch after the last queued sprint. `--queue vX.Y.Z` relocks that one, and like every relock it is the human's to run and optional (step 4). Queue them in order: a version past the chain's end is refused. How a queued sprint starts and shows is `stages.md`, "Release windows", Queued. When a sprint is shrunk and the rest should wait, tag those rows with the next version and queue it, so the human can see it.

## Do NOT

- Get around a refusal that names the frozen-sprint rule. Do not edit the sheet's tags by hand, unset the session's environment, or relock to drop a row: the cut carries open rows, and only the human overrides, from their own terminal.
- Hand-edit the `## Committed` section. The lock writes it, and the cut's score reads it back.
- Report a sprint as set up from a version tag alone. It is set up once `notes board --json` lists it under `.sprints`.
