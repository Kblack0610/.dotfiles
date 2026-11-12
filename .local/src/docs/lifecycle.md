# Lifecycle: from idea to verified

A piece of work sits at one step, from a first idea to a goal proven live. The step is worked out from the artifacts and never stored, so it cannot drift from them. "Stage" is a different ladder: a project's maturity, in `~/.local/src/docs/stages.md`.

Work enters at any step. A small fix is a row and never needs a brief. The table says what an artifact must meet if it exists.

| Step | It exists when | Template | Check |
| --- | --- | --- | --- |
| idea | a row in `<lab>/ideas.md`, or an open `decide(` row | the task row, `~/.local/src/notes-cli/README.md` | `notes ptask <p> file` |
| brief | a file in `<lab>/docs/briefs/`, with an `Epic:` line once its epic is filed | `~/.claude/skills/one-pager/SKILL.md` | its head lines are present |
| plan | a plan whose `epic:` line names the epic | `~/.local/src/docs/planning.md` | `~/.claude/hooks/plan-standard.sh` |
| epic | an `epic(<system>):` row on the human sheet | the task row, `~/.local/src/notes-cli/README.md` | `notes doctor --projects` |
| rows | its `#of/` children, and their queue items | the task row, `~/.local/src/notes-cli/README.md` | `notes ptask` |
| landed | every leaf closed with merge proof | `~/.local/bin/agent-land` | `~/.local/lib/agent-merge-proof.sh` |
| verified | the epic closed on proof of its outcome | `notes ptask <p> done --proof` | `ptask done` refuses a PR alone |

## What an epic is

- An epic is one feature: one system, one outcome the human can check by using it, usually 3 to 15 stories, closed only on proof. Its title names the outcome (`epic(gameplay): school days, choices and the morality meter`), never the work. Its area is a system id from `~/.local/src/docs/systems.md`, so a project reads as system -> feature -> story.
- Each system a project works on has one standing epic, `epic(<system>): <system> to standard`, for its criteria gaps (`project-stage-check --file` files them under it once it exists) and for fixes and upkeep that serve no feature. Every leaf has a parent: a feature epic when one fits, else its system's standing epic. `notes ptask add` and `file` link a typed leaf with no `#of/` whose area is a system id or alias to that standing epic, filing the epic on the human sheet when it is missing, so every row writer gets the link. The inbox triager owns the epic tree, with no human step: it picks the area from the project's systems, links a feature epic when one fits, and files a new feature epic tagged `#new` (listed first on the sheet) when the work is a new capability no open epic covers. It runs on every intake and nightly over every open row with no `#of/` (`agentctl-inbox-triage --backlog --link`, from `agentctl-project-index`). The human may file, retitle or drop an epic too; no other unattended writer files a feature epic. Why: an epic tree that waits on a human review goes stale (2026-11-10: 1,840 rows under no epic).
- A system's progress is the leaves-only weighted done share of its open epics plus the epics closed in the open version. `epics.rs` rolls up each epic and carries its system, and `hub_core::page` (`systems`) sums each system's percent for the project card. A project's progress is its list of systems, never one number.
- A release containing a feature epic closed on proof is a minor version (`stages.md`, "Versions").

## One key up

Every artifact points at its epic: a plan's lowercase `epic: <id>` line, a brief's `Epic: <id>` head line, a row's `#of/<id>`, a queue item through its row. The reverse links are derived, never written down. `fleet-bench epics --json` is the one reader that derives them, with each epic's step, its ETA and how that ETA ran. `hub_core::epics` types it, and `hub_core::page` joins it with the stage check and the shipped versions into the opened card, read for one project only when its card is opened: `hub projects --page NAME`, agent-web `/api/projects/{name}/page`.

A plan also names the board rows it answers on a lowercase `rows: <id>, <id>` line, a request row such as the human's `ucp-134`. When the plan's last phase lands, `agent-land --plan` closes each of them that is still open with the PR as proof, as it closes the item's own row; a row it cannot close is a line with the command, never a failed landing.

## Merged is not done

An epic whose leaves have all landed is ready to verify, and nothing closes it automatically. `fleet-dispatch` reap queues one verify item for it (`reconcile_epics`, with automation on for the profile), so it does not wait unseen: that session gathers proof of the outcome, a URL, a run or a screenshot, and closes the epic on it, posting one agent-ask only when the proof is the human's word. A part that does not work gets a gap row under the epic, and once those land the next verify is queued. `notes projects --roadmap <p> --json` lists each closed epic with that `proof`, and `verified` is false for one closed `--unverified`.

Who files an epic and who closes one: `~/.claude/skills/notes-system/SKILL.md`, "Project board".
