---
name: docs-cleanup
description: >-
  A docs cleanup pass over the agent corpus: skill-drift baseline, dead and stale claims in skills, rules, memory, anchors and lessons, fixes by cause, re-measure, report. Use for "clean up the docs", "docs pass N", "why do sessions hallucinate". One repo's docs: docs-audit.
metadata:
  category: ops
  tags: [docs, drift, lessons, memory, skills, nightly]
  reviewed: "2026-11-05"
---

# Docs cleanup

One pass that leaves the agent corpus truer than it found it: a measured baseline, every wrong or dead claim listed with what is true now, fixes landed by cause, superseded text moved out of the way, and the same numbers again at the end. A doc that names a file that is gone, a bug that is fixed, or a system that was retired is what a session acts on when it "hallucinates".

It composes skills and restates none of them: `skill-drift` counts, `docs-audit` owns the Tier 1 method (verify a claim against the code, never another doc), `skill-refine` owns judgment on a skill, `update-rules` picks the rule layer, `dotfiles-land` routes a change between the two dotfiles repos. The nightly `docs-cleanup` runner (`agentctl list --md`) takes the counts and queues this pass when there is drift.

## When to Use

- The nightly queue item, or the human asks for a docs cleanup or "docs pass N".
- Sessions keep acting on things that are no longer true: a retired runner, a moved path, a fixed bug.

Not for one repo's own docs against its code (`docs-audit`), not for code cruft (`drift-audit`), not for a rule the human just gave (`update-rules`).

## Steps

1. **In flight first.** `agent-queue list --state active`, `gh pr list` in both dotfiles repos, and `git -C ~/.agent status`. Never edit a file another session has dirty or on an open branch; leave it for the next pass.
2. **Baseline, from the scripts only.** The runner's inbox (`~/.local/state/agentctl/docs-cleanup/<date>/`) holds `skills.json` (`skill-drift --json`), `docs.json` (`skill-drift --docs --json`), `lessons.tsv` (bytes per lessons file). By hand, run the same two commands. Pass 2 onward, the last report is the baseline; re-run today's scripts rather than copying its numbers.
3. **Inventory, worst first.** Group the findings by the layer a session reads soonest: `MEMORY.md` index lines and memory files (load every session), the rule files (both CLAUDE.md, `~/.dotfiles-private/AGENTS.md`), anchors, skills, `~/.local/src/docs` and the agentctl runbooks, then lessons. For each finding: doc and line, what it says, what is true now (checked with `test -e`, `command -v`, `--help`, `git log`), and the action. A dead path is a lead, not the whole finding: read the sentence around it, since a moved file usually means the claim moved too. Also grep each layer for systems named as retired in the rules (the per-Stop LLM judge, Obsidian, ansible-vault, waves, board-runner) still written as live. Every memory file gets a Tier 1 read each pass, flagged or not: a memory about a bug that has since been fixed names only live paths, so skill-drift never flags it (pass 1 found 25 of 38 dotfiles memories stale, most with no dead path).
4. **Fix by cause, one area per PR.** Skills and rules: a branch per area under `~/.worktrees/`, routed by `dotfiles-land`, rule edits through `update-rules`, a skill's `metadata.reviewed` bumped only after checking it. Memory files and anchors: edit in place; delete a memory whose whole fact is a fixed bug and drop its index line. Fix PRs merge with `gh pr checks <N> --watch` then `gh pr merge <N> --squash`; only the report closes the queue item with `agent-land`, because the item is inherited.
5. **Lessons: rewrite, never pile up.** A correction chain (an entry plus the ones that say "correcting", "SUPERSEDED", "REFUTES" about it) becomes one entry saying what is true now. The replaced text and any entry about a retired system move to `~/.agent/lessons/_archive/<project>-superseded.md` with a line naming what replaced it; nothing is deleted. Work through dream's "Superseded, for removal" list in `~/.agent/dreams/<project>/DREAMS.md` first, then the dead-path entries `docs.json` lists, at most 40 entries a pass so each one is checked.
6. **Re-measure** with the same two commands and `wc -c` on the lessons files. Say what went down, what did not and why.
7. **Report** in `~/.agent/plans/dotfiles/docs-cleanup.md` (current pass only; git history in `~/.agent` keeps the old ones): a before/after table for every step-2 number, fixed (finding -> PR or file), archived (count per lessons file), kept with a why, and left for the next pass. Then `agent-land` the last PR with `--item $AGENT_QUEUE_ITEM`, or `agent-queue move $AGENT_QUEUE_ITEM done --status ok` when no PR was needed.

## Do NOT

- Do not verify a claim against another doc; two docs agreeing is usually a copy.
- Do not delete a lesson or silence a finding with `skill-drift: ignore` to make a number drop; move it to `_archive/` or fix the claim.
- Do not touch auth tokens, history, logs or sqlite state, and do not edit mem0 (its queue stays human-gated).
- Do not restate skill-drift, docs-audit, skill-refine or update-rules here; link them.
