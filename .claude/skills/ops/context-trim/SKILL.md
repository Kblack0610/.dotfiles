---
name: context-trim
description: >-
  A fixed-context trim pass: measure what loads on every turn, cut duplicates, restated skills, stale and misplaced text, prove no rule or hard scenario was lost, re-measure. Use for "trim the context", "cleanup/trim pass N", "CLAUDE.md is too big". Stale claims: docs-cleanup.
metadata:
  category: ops
  tags: [context, tokens, claude-md, memory, rules, scenarios]
  reviewed: "2026-11-07"
---

# Context trim

One pass that makes the text sent on every request smaller without losing a rule. The method (finding shape, in flight, baseline, one lever per PR, re-measure, proposals, next pass) is `~/.local/src/docs/analysis-streams.md`; this file holds what is specific to fixed context.

The size of each part comes from `agent-usage burn --json` (`first_request_parts` per start, `every_request_parts` `context_share` across the window); the bytes of each home from `wc -c`. What must survive comes from the rule register, `~/.config/agentctl/rules.jsonl`, read by `fleet-bench rules`. Restated text comes from `skill-drift --dups`. Budgets are the ones `~/.claude/hooks/context-budget-guard.sh` warns on.

## Scope and triggers

- The human asks for a trim or "cleanup/trim pass N", or a fixed part grows past its budget.
- After a trim lands, to prove what it saved.

Siblings: stale or wrong claims are `docs-cleanup`; a rule the human just gave is `update-rules`; which skills are listed name-only is the skill-usage toggle (`skillOverrides` in user settings). Built-in tool schemas and the system prompt are not ours to cut.

## Parts and their homes

| Part (`agent-usage burn`) | Home | How it lands |
|---|---|---|
| `global_claude_md` | `~/.dotfiles-private/.claude/CLAUDE.md` | private PR, `update-rules` |
| `repo_claude_md` | each repo's root `CLAUDE.md` or `AGENTS.md` | one PR in that repo; another repo's is a queue item for it |
| `memory_md` | `~/.claude/projects/*/memory/MEMORY.md` | edit in place, detail into topic files |
| `preflight` | `.config/shared-hooks/session-preflight.sh` output | public PR |
| `agent_listing` | `.claude/agents/*.md` descriptions, both repos | PR per repo |
| `skill_listing` | skill descriptions (`LONGDESC`, `LISTBUDGET`) | PR per repo |

## Hard scenarios

A hard scenario is a situation where a session without the rule's text does something costly or irreversible. It is a register row with a `scenario` field next to the rule's `anchor`, and `fleet-bench rules --scenarios` lists them as ok, stale or absent. Every invariant row carries one.

- A trim may reword a scenario rule, but it changes the row's `anchor` in the same PR and keeps the decision the scenario needs. It never removes a scenario row or its rule; only the human does.
- `fleet-bench rules --check` is green and the `scenarios=` count is unchanged before and after. The private repo's `tests/rules-register.bats` fails a PR that drops the text of any row sourced there.
- Code review reads each scenario whose source the PR touched against the new text: does what is left still decide that situation?
- A cut that finds a rule with no row adds the row first, so the cut is checked.

## Steps

1. **In flight first,** per the method. Another session's open PR on a home is theirs; leave that home for the next pass.
2. **Baseline.** `agent-usage burn --days 7 --json` into `~/.cache/context-trim/p<N>/`, `wc -c` on every home above, `fleet-bench rules` (the `scenarios=` line) and `fleet-bench rules --check`.
3. **Cut by cause,** largest part first, in this order:
   - duplicate: the rule already has a home (`skill-drift --dups` names the winner); delete the copy;
   - restated skill: a procedure or description a skill owns; name the skill instead;
   - wrong layer: text that applies to one repo, one subtree or one procedure moves to that repo's CLAUDE.md, a path-scoped `.claude/rules` file, the skill, or a memory topic file;
   - history: incident narratives, dates and superseded wording; the rule says what is true now and git keeps the rest;
   - padding: words that do not change what a session does. A rule keeps its one-line why.
4. **Prove nothing was lost.** Step 2's register commands again, and the scenario read in "Hard scenarios". A red is fixed by restoring the text, never by editing the row away.
5. **Land,** one part per PR through `dotfiles-land`, `/code-review high` on any PR that touches a scenario rule.
6. **Re-measure.** Bytes per home now; `agent-usage burn` over the same window length once a week of sessions has the change, queued as an `at:` item per the method.
7. **Report** in `~/.notes/lab/projects/current/agent-runtime/docs/context-trim-p<N>.md`: one row per part with a column per measured point, what was cut and where each moved, the scenario count before and after, what was kept and why, and what is left. Queue the next pass per the method (slug `context-trim-p<N+1>`).

## Do NOT

- Do not cut a rule because it is long; cut what restates, misplaces or pads it.
- Do not delete a memory, lesson or rule outright when it is only misplaced; move it to its narrower home.
- Do not restate `analysis-streams.md`, `update-rules`, `docs-cleanup` or `usage-cleanup` here; name them.
