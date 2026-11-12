---
name: go
description: >-
  Decide and proceed instead of asking: best-practice pick, logged assumptions, stop only at hard gates. `/go` covers this checkpoint; `/go all` or `/go <scope>` holds it for the whole task. Use for "go", "just decide", "stay autonomous". End to end with landing: one-shot.
argument-hint: "[all | scope, e.g. 'until CI is green']"
metadata:
  category: workstreams
  tags: [autonomy, decisions, session]
  reviewed: "2026-11-12"
---

# go

You are at a decision point: a question you would normally ask, a plan awaiting approval, or an ambiguous fork. Do not ask. Make the call, record it, and keep going. This is the `kb-coordinator` operating posture (`~/.dotfiles/.claude/agents/kb-coordinator.md`) on demand. `one-shot` runs its whole task in standing mode.

## Scope and triggers

- `/go`: this checkpoint and its immediate next steps, then yield at the next natural stopping point.
- `/go all`: standing mode until the task is complete.
- `/go <scope>` (for example "until CI is green", "this feature"): standing mode until that scope is met.

Not for taking a task all the way to merged and wound down - that is `one-shot`. Not for extra design care - that is `rigor`, which stacks with this (`/rigor /go all`).

## Decision rule

Choose the option that best balances **correctness -> maintainability -> scalability -> simplicity** for this specific use case, not in the abstract.

- Take an already-recommended option (a plan, an option marked "Recommended", a default) unless something the human said contradicts it.
- Prefer existing patterns, utilities and conventions over net-new code. Grep and reuse first.
- Do not gold-plate: the smallest change that fully solves it.

Do not re-pose the question. Execute the chosen path.

## Hard-stop boundary (the only thing that pauses you)

Irreversible or outward-facing actions only:

- Destructive or data-loss ops: deleting files you did not create, dropping tables, overwriting state with no backup.
- Release tags, `deploy.sh`, widening a rollout, a rollback, any human approval gate. The release-coordinator **Hard constraints** apply verbatim (`~/.claude/skills/release-coordinator/SKILL.md`); do not restate or weaken them.
- Money, auth, secrets and tokens, anything sent to an external service or another person.
- Never force push, on any branch, and never offer it: if pushed history is wrong, use a new branch and a new PR.

A gate pauses that one action, never the run: build everything up to it with the switch off, open the PR, post one `agent-ask` with the exact commands you would run, then carry on with every step that does not need it. Before calling a secret the human's to provide, look on the box (`rbw list`, `sops -d` on the repo's secrets); writing a sops secret whose value you have is yours. "Human approval gate" means the release constraints and any gate the human named. Approving your own plan, or splitting the ask into phases, is not one: the ask already authorizes every phase of it.

## Named-risk stop

The only other reason to pause. Stop and ask, with your recommendation, when you can STATE a concrete risk: it conflicts with another session's open work, it changes shared behaviour other games or sessions depend on, it undoes or fights something already landed, or it is likely to give a bad result for the player. "Unsure" is not a risk; name it or proceed.

## Log assumptions

Each non-obvious choice is a line in your reply, `assumed: <the choice> because <the reason>`, and is persisted into the plan or PR body (its `## Assumptions` section) when one exists.

## Standing mode (`/go all`, `/go <scope>`)

1. **Hold the posture.** Resolve every later fork, question and plan-approval point the same way until the scope is met, a hard gate waits on the human, or they say stop. When a plan is ready, take the recommended approach and `ExitPlanMode`.
2. **Sanity check before each new phase.** Re-read the ask and the plan (still wanted?); `git fetch` and check origin/main has not already done or changed it; check no other live session or open PR is on the same files (`gh pr list --state open`, `fleet-sessions`). One fails: that is your named risk. A nightly red is never one, unless your own merged PR is a suspect for it (then fixing it is your next step).
3. **Do it now; queueing is not doing.** This overrides every "queue it", "board row", "later phase" and "next pass" rule. It does not touch the hard-stop boundary, the named-risk stop, ask-first repos, another session's dirty files, or a fleet-pace hold.
   - Run phases back to back in this session. Do not `agent-queue add --after` the next phase, wind down between phases, or hand a phase to another session.
   - A follow-up found inside the scope (a bug next door, a stale doc, a missing test) is done now, in its own PR when it is a separate change. Context size is not a reason to stop.
   - Queue or board something ONLY when this session cannot do it: it needs a set time, a day of data or tonight's run; it waits on a PR another live session owns; a fleet-pace hold covers it; or it is outside the scope. Each item names its blocker. A hard gate is an `agent-ask`, never a queue item.
4. **Assumption digest.** Every few decisions or per milestone, print the `assumed:` lines so far, so the human can audit without interrupting.
5. **Resume cleanly.** When the human clears a hard gate, continue in standing mode without re-asking the reversible decisions.
6. **Exit report.** Report what you did, the full assumption tally, and every item you queued or boarded with its blocker. One without a blocker is not done: go do it.

## Do NOT

- Ask the human about a reversible choice. That is the question this skill exists to remove.
- Treat a hard gate as a reason to stop the whole run: it pauses that one action.
