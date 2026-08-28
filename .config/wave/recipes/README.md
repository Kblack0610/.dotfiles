# Wave recipes

A **recipe** is a prepared maintenance wave: an audit plus a proposal step. `/wave <app> propose <recipe>` runs the recipe's discovery against the repo, turns what it finds into concrete items on the project's sheet, and stops. The normal `/wave <app> start` gate then approves them like any other wave.

## Why these exist

A wave's work comes from the open lines under `## Wave: <ver>` on the project sheet, written by a human. That is right for bugs: a human found it, a human describes it. But it means the standing maintenance every project accumulates - dead code, logic implemented four ways, a module nothing tests - only ever happens if someone sits down and types the items out. The batch machinery was built; the ability to stock it was not. A recipe stocks it.

## The one rule: a recipe feeds the front door, it is not a second door

Discovery writes its findings to the **sheet**, through `notes ptask <app> add`. It does not write a board, create a ticket, or cut a branch. Everything downstream - the scope gate, the blackboard, the branch, the draft PR, the roll - is the existing `/wave start` path, unchanged and unaware a recipe was involved.

This is deliberate. A recipe that wrote its own board would be a second source of work with its own half-copy of the wave lifecycle, and the two would drift. The sheet is the front door; a recipe is a way of stocking it, not a way around it.

It also keeps the human in the same place they already are. Proposed items land on their list, in their lane marker, next to the bugs they wrote themselves, and they approve the batch at the gate they already know.

## Recipe format

Frontmatter:

| key | meaning |
|---|---|
| `name` | the token passed to `propose`; matches the filename |
| `description` | one line, shown when listing recipes |
| `cap` | most items to propose in one pass. Default 8, the wave cap - a wave past ~8 cannot attribute a red e2e |
| `applies-to` | `any`, or a coarse repo shape (`js`, `rust`, `shell`) used to skip probes that cannot apply |

Then two sections:

- `## Discovery` - the read-only probes, each with what a hit MEANS. Not a script: the model runs these and reads the output, so a probe that needs judgement is fine.
- `## Item shape` - how to turn a finding into one sheet line, with worked examples.

## Hard rules for every recipe

**Discovery is read-only.** No formatter, no codemod, no `--fix`, no `--write`, no branch. A probe that mutates the tree has already made the change the wave was supposed to gate. If a tool only offers a fixing mode, run it against a scratch copy or do not run it.

**An absent tool is SKIPPED, not failed.** Not every repo has `knip`, `syncpack` or `cargo-udeps`. A missing binary means that probe contributes nothing; it does not fail the pass and it does not get proposed as "install knip". Say in the ask which probes were skipped, so a thin proposal is legible as thin coverage rather than a clean repo.

**Propose findings, never chores.** "Remove the 4 unused exports in `packages/ui/src/index.ts`" is a finding: it names a place and a count, and it is done when they are gone. "Improve code quality" is a chore. If a probe cannot produce a location and a scope, it is not ready to be an item.

**Respect the cap and say what was cut.** At most `cap` items. If discovery found more, take the highest-value ones and name the count left behind in the ask - a silently truncated list reads as a clean repo, which is the failure mode this whole harness keeps hitting.

**Nothing risky rides a maintenance wave.** A finding that needs a schema change, a data migration, a dependency major bump, or that touches auth/billing is reported in the ask as out-of-scope rather than proposed as an item. Those want their own wave with their own gate.

**One line, plain ASCII, no ticket ids.** The sheet line is a task title, and `/wave start` will draft the ticket from it.

## Catalog

| recipe | proposes |
|---|---|
| `cleanup.md` | dead code, unused deps, version mismatches, stale paths, debt markers |
| `consolidate.md` | logic implemented N ways that wants one shared home |
| `harden.md` | untested paths, unchecked failures, gates that pass on empty input |

## Adding one

Copy the closest existing recipe. A new recipe earns its place when its findings are things a human keeps re-noticing by hand - if you have written the same kind of item on three projects, that is the recipe. Keep the probes cheap enough to run on every project without thinking about it.
