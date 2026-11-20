---
name: sprint
description: >-
  Run a project sprint on the notes board: lock one for N hours, check it, relock when blocked rows unblock, take a mid-sprint ask, read the cut score. Use for "set up a sprint", "is the sprint set up", "lock a sprint". Fix or re-send a cut: release.
metadata:
  category: workstreams
  tags: [sprint, release-window, notes, board]
  reviewed: "2026-11-19"
---

# Sprint

A project's sprint is its open version's release window: the rows it commits to, the only lane new asks get in by, and the score at the cut. The rules live in `~/.local/src/docs/stages.md`, "Release windows"; this skill is the commands that run them, so a session does not have to dig them out of notes-cli.

## Scope and triggers

- When the human asks whether a project has a sprint, or to set one up, shorten one or lock one for a number of hours.
- When a row that sprint rows waited on has merged, and the sprint should take them in.
- When a new ask arrives mid-sprint and has to go in now, or wait for the next version.
- When a sprint's cut time has passed and the human asks why nothing moved.

Not for fixing or re-sending a release the system cut (builds, Steam upload, the default click): that is `release`; no session cuts one. Not for choosing which epics a version holds: `release-coordinator`. Not for board hygiene: `board-cleanup`.

## Where a sprint lives

- The snapshot is the `## Committed` section of the open version's agent note. `notes projects --agent-note <project>` prints its path, and creates the note when it is missing, so use it only to read a snapshot step 1 already found; the head line carries `opened=`, `due=`, and for a locked sprint `locked=` and `cut=`.
- Only a `#prio/focus` project runs sprints (`stages.md`, "Release windows"). `notes board --json` lists its open window, and the next one queued behind it, under `.sprints`: `project`, `profile`, `version`, `committed`, `done`, `carried`, `opened`, `locked`, `cut`, `due`, `remaining_weight`, `rate_per_hour`, `tasks`, `queued`, `start`. Projects > Board shows the same rows in its Sprints table.
- A project with no entry there has no sprint: either it is not focus (its window, if any, still scores its cut and sets its state word) or it has no window (`no window`, `stages.md`, "Project state"). To give a project a sprint, the human makes it focus first: `notes projects --prio <project> --set focus`.
- A project name resolves across profiles, so `--profile` is not needed.

## Steps

1. **Read the state first.** Check the project is focus; if `notes projects --prio <project>` does not print `focus`, it has no sprint to read or lock, so ask the human whether to make it focus before any step below.

   ```bash
   notes projects --prio <project>
   notes board --json | jq '.sprints[] | select(.project=="<project>") | del(.tasks)'
   ```

   Report what is there: the version, done of committed, the cut, and what the projected finish (`remaining_weight` over `rate_per_hour`) says about making it.

2. **Put the rows on the open version.** A lock takes the open version's rows (the sheet's `Version:` line): untagged rows and rows tagged at or below it. Rows aimed at a later `#vX.Y.Z` stay out. If the human wants those in, retag only them to the open version first, and say so in the report.

3. **Lock the sprint.**

   ```bash
   notes projects --commit <project> --hours <h>
   ```

   `--hours` runs from one minute up to 720 hours. The command prints the rows committed, the capacity they filled, how many rows the earlier snapshot held, and the pinned rows left out. What it does:
   - The capacity is what the agent lane shipped over its budget window, scaled to `h` hours.
   - Rows fill it in this order: `#urgent`, then in progress, then `#requested`, then the rest, smallest first within each. A row too heavy for what is left is skipped.
   - A row that cannot land by the cut is left out: one behind `#after/<id>` of a row still open, or one held by an `#at/` gate that opens at or after the cut or cannot be read (a malformed `#at/9pm` keeps a row out).
   - The human lane commits nothing, because it has no measured pace.
   - It replaces any earlier snapshot. Tell the human what the old one held (the "replaced N" count) before or as you report the new one.
   - A lock that would commit no rows is refused, and the earlier snapshot stays.

   `--commit <project>` without `--hours` only records a window that opened with no snapshot, due on the cadence day. It never replaces one.

4. **Relock when blockers land.** When a row that sprint rows waited on (`#after/`) merges, run step 3 again. The sprint then takes in what can now land. Relocking is the only way rows that were left out get in. A relock restarts the window: the new snapshot holds only rows still open, so rows already delivered drop out of the score, open `#interrupt` rows count as committed, and the cut moves to now plus `--hours`. Before relocking, note the current cut and done count, pick `--hours` as the hours left to the cut the human set, and tell the human the score restarts.

5. **Mid-sprint asks.** In a `#prio/focus` project with a snapshot, a new row goes to the next patch version unless it is an interrupt. An interrupt is the human at a terminal, their inbox lines, a `--want` channel other than `outbox` or `ask`, a row tagged `#interrupt` or `#urgent`, or one aimed at the open version by hand. Interrupts join the open window, tagged `#interrupt`, and the cut counts them as `interrupted`. Do not relock just to fit one ask in: an interrupt already gets in.

6. **The cut.** `cut=` is when the sprint is due. Passing it rolls nothing: the board keeps the sprint listed, showing its past cut, until the version rolls. The version itself moves on:
   - For a project its git tag owns, when the release tag ships. `agentctl-wave-roll` then rolls the sheet and carries the open rows.
   - For a sheet-counter project, when `agentctl-wave-roll` cuts it after its cadence has passed with done rows.

   The roll writes the score (committed, delivered, carried, dropped, interrupted) under `## Window` in the frozen version note. For a tag-owned project, `notes-roll` by hand refuses to freeze a version no tag ships. That refusal is correct: put the rows on the open version (step 2) instead of forcing a roll.

7. **Queued sprints.** Any number chain behind the open one. Aim the rows at the version first (`notes ptask <p> move <id> --to vX.Y.Z`), then `notes projects --commit <p> --hours <h> --queue` locks the patch after the last queued sprint, starting at its cut; `--queue vX.Y.Z` relocks that one, and a relock moves the sprints behind it. Queue them in order: a version past the chain's end is refused. Each shows on Projects > Board as a `queued` row (`stages.md`, "Release windows"). When a sprint is shrunk and the rest should wait, tag those rows with the next version and queue it, so the human can see it.

## Do NOT

- Override the roll's tag check (`ROLL_TAG_CHECK=off`) to move a sprint on past a release hold. Only the hold decides when the version ships.
- Hand-edit the `## Committed` section. The lock writes it, and the cut's score reads it back.
- Report a sprint as set up from a version tag alone. It is set up once `notes board --json` lists it under `.sprints`.
