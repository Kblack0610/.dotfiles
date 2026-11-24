---
name: answer-pass
description: >-
  A human-invoked pass over waiting asks: fetch the facts each one defers on, score it by the judge's policy.md, then answer, close, park or recommend. `/answer-pass [ids|project] [--review]`. Filing or unsticking one ask: fleet-asks.
argument-hint: "[<ask id>... | <project> | --all] [--review]"
disable-model-invocation: true
metadata:
  category: monitoring
  tags: [agent-ask, asks, judge, policy, answer]
  system: [sessions]
  reviewed: "2026-11-23"
---

# answer-pass

The judge scores an ask on its text alone, in 30 seconds, so an ask that defers on a fact the judge cannot read (a PR merged since, a queue item done, a file at HEAD, a choice the human made last week) stays with the human although an agent could settle it. This pass fetches those facts fresh, scores each ask by the judge's own rules (`~/.config/agent-ask/policy.md`) with them in hand, and acts: an answer, a close or a park for what policy lets an agent settle, a fresh recommendation for what stays the human's. The human typing `/answer-pass` is the go for every act policy allows; `--review` writes the tables first and waits for go.

## Scope and triggers

- The human runs `/answer-pass` with ask ids, a project or `--all` (no argument: the pending asks of the current project).
- `--review`: the human wants to see the picks before anything runs ("go over my asks", which `fleet-asks` routes here).

Not for filing an ask, reading one answer, or an answered ask that went nowhere: `fleet-asks`. Not for proposals: `fleet-asks` "Review proposals". Not for counting what waits on the human: `fleet-bench asks`.

## Steps

1. **Gather.** Ids given: `agent-ask show <id>` each. Else `agent-ask list <project|--all> --pending` (parked asks are left out until their date). `--review` reads the whole pile: `fleet-bench asks` (hub Home's order), `agent-ask list --all --open` (pending and parked) and `agent-ask resumable --all` (answered, nothing moved; `ask-resume <id>` is for those rows only, as `fleet-asks` "Stuck asks" says). Over about 15 asks, split steps 2 and 3 by project across read-only Explore agents that return one row each (id, outcome, pick, evidence); this session merges the rows and runs every verb.
2. **Name what each ask defers on.** Read `agent-ask card <id>`: the question, option meanings, the recommendation and its why, `answer releases:` (the queue items and rows an answer starts) and last the judge line. Then list each fact the call turns on: the judge's `judge_rule` and `judge_evidence` (the criterion it found met, and the words it quoted), and every premise the context states (a PR is open or red, an item waits, a file says X, the human said Y).
3. **Fetch each fact now.** The state as filed may be stale; one source per kind:
   - A PR or check: `gh pr view <N> --json state,mergedAt,statusCheckRollup`.
   - A queue item or board row: `agent-queue show <slug>`, `notes ptask <project> --agent list`.
   - Code or a doc: `git log origin/main --since <posted>` in the repo it cites, the file:line at `origin/main`.
   - Live state: `systemctl --user`, `kubectl` with the target cluster named first, never assumed to be prod.
   - What the human decided before: `agent-ask precedents <posted>` (their disagreements with the judge), `agent-ask list --all --answered --since 30d` for the same decision, `agent-hold list` for holds, and `~/.agent/lessons/<project>.md`.
   - The asking session: `agent-ask target <id>` (live, ended or gone).
   What no command can fetch (the human's schedule, taste, a login only they hold) stays unfetched, and the ask stays theirs.
4. **Score by policy.md.** Read `~/.config/agent-ask/policy.md` once per pass and score every decision of each ask as it says, with the fetched facts as part of the ask: a fact you fetched is no longer `knowledge`, and a choice the human already made is `against-precedent` for any other pick. Then give each ask one outcome:
   - Close: events settled it (the PR merged, the item is done, the row was answered, a hold or an older ask decides it). `agent-ask cancel <id> '<the fact, with its source>'`. Stale audits, idle asks, asks whose today or tonight is over, asks on a row the human has since answered, asks a hold decides and duplicates close on their own (`assume-due` runs `expire`, and the judge's `settled_by` takes the rest: agent-ask README "Asks that settle themselves"), so one of those still pending is a case the closers missed: say which closer should have caught it.
   - Answer: no criterion under "The human's" is met, `reversible` is met, and `answer` takes it (it refuses an approval, an ask the judge marked human-only and one at the human floor). `agent-ask answer <id> '<option>: <the fact that picked it>'`; keep every other option slug out of the reason, since `answer-names` reads the slugs the text names. When `grounded` is not met (the pick only follows the asker's recommendation, with nothing fetched behind it), say so in the report.
   - Park: it waits on something not yet true (a PR not landed, a date). `agent-ask park <id> --until <date>`; it leaves `--pending` and the boards until then, and with no `--until` the date comes from the held item's priority (`park.conf` PARK_DAYS).
   - Only the human: any criterion under "The human's" holds, the answer would cancel work the human asked for, or `answer` refuses it. `agent-ask recommend <id> <option> '<the fact you fetched that decides it>'`, so their card carries the fresh fact; when no fact changes the pick, leave the recommendation as it is.
   An answer starts the work the card lists under `answer releases:`, so check that premise before you answer.
5. **Act.** Without `--review`, act now; with it, write step 6's tables, run nothing, and act when the human says go, on the rows they approve. Either way, per ask, `agent-ask show <id>` first and act only while it is still pending: one the judge, a session or the human settled meanwhile is skipped and named in the report, since cancelling an answered ask fails the items it holds. A refused `answer` (it needs the human) moves the row to Only the human.
6. **Report** per `comms-standard`: one table per outcome (Closed, Answered, Parked, Only the human), each row the id, the question in a few words, the pick and one line of evidence with its source. Under Only the human, give what they run, bare with no leading `!`, and what declining costs, then explain each in plain words: what it is for and what happens if they skip it. End with the counts: asks read, closed, answered, parked, left.

## Do NOT

- Answer from the recommendation alone without fetching what the ask defers on: that is what the judge already did, and it is why the ask is still waiting.
- Answer an approval, an ask the judge marked human-only, or one at the human floor, or try to get round `answer`'s refusal (`--by human` from a session is refused too). Recommend and leave it.
- Ask the human again for a choice they already made: read the precedents and answered asks first, and answer or close by that choice.
- Edit files under `~/.agent/asks/` by hand, or run `agent-ask sweep` or `ask-resume` as part of the pass: `sweep` re-scores the queue on the judge's text-only view, and `answer` already delivers.
