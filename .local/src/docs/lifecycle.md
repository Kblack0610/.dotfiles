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
- Each system a project works on has one standing epic, `epic(<system>): <system> to standard`, for its criteria gaps (`project-stage-check --file` files them under it once it exists) and for fixes and upkeep that serve no feature. Every leaf has a parent: a feature epic when one fits, else its system's standing epic. `notes ptask add` and `file` link a typed leaf with no `#of/` whose area is a system id or alias to that standing epic, filing the epic on the human sheet when it is missing, so every row writer gets the link. A stage's gaps go the same way under `epic(stage): <stage> to standard`, which `project-stage-check --file` files when missing (`stages.md`). The inbox triager owns the epic tree, with no human step: it picks the area from the project's systems, links a feature epic when one fits, and files a new feature epic tagged `#new` (listed first on the sheet) when the work is a new capability no open epic covers. It runs on every intake and nightly over every open row with no `#of/` (`agentctl-inbox-triage --backlog --link`, from `agentctl-project-index`). The human may file, retitle or drop an epic too. A session the human opened files one through the self-check `notes ptask add` runs (a plan's `epic: new` line, filed at approval: `planning.md`, Epic:); any other agent writer proposes it, an `epic(` line that goes to the outbox for the triager's verdict, and never files one itself. Why: an epic tree that waits on a human review goes stale (2026-11-10: 1,840 rows under no epic).
- A system's progress is the leaves-only weighted done share of its open epics plus the epics closed in the open version. `epics.rs` rolls up each epic and carries its system, and `hub_core::page` (`systems`) sums each system's percent for the project card. A project's progress is its list of systems, never one number.
- A release containing a feature epic closed on proof is a minor version (`stages.md`, "Versions").

## Writing an epic's stories

- A story is one PR in one area: `#size/s` or `#size/m`, filed on the agent board as `type(area): title #of/<epic>`, clear enough for dispatch to pick (the `fleet-dispatch` skill names what it skips). A leaf that would be `#size/l` needs a plan; that plan carries the epic's `epic:` line, and each of its phases is filed as one more story of the epic.
- Its title is a checkable outcome, smaller than the epic's, and one detail line says what done looks like: the test, the run or the surface to look at.
- Stories on the board are independent of each other: the board ranks rows by priority but has no dependency order. When one needs another first, the order goes in a plan's `## Phases` markers (`(after N; needs <result>)`, fleet-queue skill), never in prose on a row. A phase waits only for a result it consumes, never because both edit one file: that is a merge the second lander resolves, and `agent-queue add --plan` refuses it.
- A feature epic usually has 3 to 15 stories; far past 15 it is usually two outcomes, so split it. A standing epic has no such bound. No "verify" story where automation is on for the profile: `reconcile_epics` queues that (below, "Merged is not done").

## Taking an epic on

The first path that fits wins:

1. The human first: the outcome is not stated, or an open `decide(` row or ask blocks it. It waits on that answer; a `design(` row is filed only after the human says yes (notes-system skill, "Project board").
2. A plan chain, `agent-queue add --plan` with a fresh session per phase: the stories must land in order, share a design decision that has to stay consistent, or one leaf is `#size/l`. It needs a plan with an `epic:` line that the human approved or an answered ask settled, and each phase is one PR; an `epic: new` proposal still waiting on the triager holds the chain, and a dropped one stops it until the plan names an epic. Only the human's `--plan` writes the phase items; from a dispatched session or a script it files one board row titled by the plan's heading and slug (`plan_row_title`), which dispatch queues as the same chain when it promotes the row (agentctl `QUEUE.md`, "Admission"). A phase waits (`(after N)`) only when phase N's output is its input; phases that only share files run in parallel and the one that lands second resolves the conflict, since a merge-order gate holds the later phase for as long as the earlier one sits in the landing queue.
3. The board, the default: the stories are independent and each is s or m. Dispatch takes them leaf by leaf in priority order; a story it cannot take (human-only, two areas) is rewritten or split, never left to wait.

Dispatch applies these paths when an epic row is started (the hub's Start, `fleet-dispatch start`, a pull after its gate clears; `take_epic`): a gate on the epic row itself, an open `decide(` leaf, or a plan of it not yet approved holds it for the human; a plan the human approved whose session is gone is queued as its chain; otherwise its stories stay on the board, and the human's Start tags the s and m ones `#requested`. It never queues the epic row as an item.

Never one long-lived session holding the whole epic: its context grows until it loses the thread, so a chain starts a fresh session for each phase. What holds it: `go` and `one-shot` file a plan with more than one open phase with `add --plan` and stop, building none of it themselves, and `plan-standard.sh` denies a plan with more than one open phase that says it runs in this session or one session (`planning.md`, Chain:).

## One key up

Every artifact points at its epic: a plan's lowercase `epic: <id>` line, a brief's `Epic: <id>` head line, a row's `#of/<id>`, a queue item through its row. The reverse links are derived, never written down. `fleet-bench epics --json` is the one reader that derives them, with each epic's step, its ETA and how that ETA ran. `hub_core::epics` types it, and `hub_core::page` joins it with the stage check and the shipped versions into the opened card, read for one project only when its card is opened: `hub projects --page NAME`, agent-web `/api/projects/{name}/page`.

A plan also names the board rows it answers on a lowercase `rows: <id>, <id>` line, a request row such as the human's `ucp-134`. When the plan's last phase lands, `agent-land --plan` closes each of them that is still open with the PR as proof, as it closes the item's own row; a row it cannot close is a line with the command, never a failed landing.

## Merged is not done

An epic whose leaves have all landed is ready to verify, and nothing closes it automatically. `fleet-dispatch` reap queues one verify item for it (`reconcile_epics`, with automation on for the profile), so it does not wait unseen: that session gathers proof of the outcome, a URL, a run or a screenshot, and closes the epic on it, posting one agent-ask only when the proof is the human's word. Its own story row carries `#of/<epic>`, so the item links the epic it checks, but a `check(epics)` row is no leaf of it: it neither holds the epic open nor counts toward the next verify. A part that does not work gets a gap row under the epic, and once those land the next verify is queued. `notes projects --roadmap <p> --json` lists each closed epic with that `proof`, and `verified` is false for one closed `--unverified`.

Who files an epic and who closes one: `~/.claude/skills/notes-system/SKILL.md`, "Project board".
