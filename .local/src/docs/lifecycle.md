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

## One key up

Every artifact points at its epic: a plan's lowercase `epic: <id>` line, a brief's `Epic: <id>` head line, a row's `#of/<id>`, a queue item through its row. The reverse links are derived, never written down. `fleet-bench epics --json` is the one reader that derives them, with each epic's step, its ETA and how that ETA ran. `hub_core::epics` types it for the surfaces and reads one project only when its card is opened: `hub projects --epics NAME`, agent-web `/api/projects/{name}/epics`.

## Merged is not done

An epic whose leaves have all landed is ready to verify, and nothing closes it automatically. Closing it takes proof of the outcome: a URL, a run, a screenshot, the human's word. `notes projects --roadmap <p> --json` lists each closed epic with that `proof`, and `verified` is false for one closed `--unverified`.

Who files an epic and who closes one: `~/.claude/skills/notes-system/SKILL.md`, "Project board".
