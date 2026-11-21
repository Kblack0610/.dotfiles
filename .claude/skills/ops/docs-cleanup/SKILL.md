---
name: docs-cleanup
description: >-
  A docs cleanup pass over the agent corpus: skill-drift baseline, dead and stale claims in skills, rules, memory, anchors, lessons and the knowledge base, fixes by cause, re-measure, report. Use for "clean up the docs", "docs pass N", "why do sessions hallucinate". One repo's docs: docs-audit.
metadata:
  category: ops
  tags: [docs, drift, lessons, memory, skills, knowledge, nightly]
  system: [docs, notes]
  reviewed: "2026-11-19"
---

# Docs cleanup

One pass that leaves the agent corpus truer than it found it: every wrong or dead claim listed with what is true now and fixed by cause, and superseded text moved out of the way. The pass itself (finding shape, in flight, baseline, re-measure, report, proposals) is `~/.local/src/docs/analysis-streams.md`; read it first. This file holds what is specific to docs, and it fixes one area per PR and queues no next pass (the nightly runner does). A doc that names a file that is gone, a bug that is fixed, or a system that was retired is what a session acts on when it "hallucinates".

It composes skills and restates none of them: `skill-drift` counts, `docs-audit` owns the Tier 1 method (verify a claim against the code, never another doc), `skill-refine` owns judgment on a skill, `update-rules` picks the rule layer, `dotfiles-land` routes a change between the two dotfiles repos. The nightly `docs-cleanup` runner (`agentctl list --md`) takes the counts and queues this pass when there is drift.

## Scope and triggers

- The nightly queue item, or the human asks for a docs cleanup or "docs pass N".
- Sessions keep acting on things that are no longer true: a retired runner, a moved path, a fixed bug.

Not for one repo's own docs against its code (`docs-audit`), not for code cruft (`drift-audit`), not for a rule the human just gave (`update-rules`).

## Steps

1. **In flight first,** per the method, on both dotfiles repos, plus `git -C ~/.agent status` for files another session has dirty.
2. **Baseline, from the scripts only.** The runner's inbox (`~/.local/state/agentctl/docs-cleanup/<date>/`) holds `skills.json` (`skill-drift --json`), `docs.json` (`skill-drift --docs --json`), `dups.json` (`skill-drift --dups --check --json`: restated instructions, the pairs over `dup_pairs_max` are the drift; delete the loser's line, then lower the row), `lessons.tsv` (bytes per lessons file), `chains.tsv` (`lessons chains`: each entry whose supersedes marker names an older one, or a key no entry carries any more), `retired.tsv` (`knowledge-retired`: hosts that left the home-config inventory and commands deleted from `.local/bin`, from git history) and `knowledge.json` (`notes knowledge lint --json --retired retired.tsv`: drift per class in `~/.notes/knowledge`). By hand, run the same commands.
3. **Inventory, worst first.** Group the findings by the layer a session reads soonest: `MEMORY.md` index lines and memory files (load every session), the rule files (both CLAUDE.md, `~/.dotfiles-private/AGENTS.md`), anchors, skills, `~/.local/src/docs` and the agentctl runbooks, then lessons. For each finding: doc and line, what it says, what is true now (checked with `test -e`, `command -v`, `--help`, `git log`), and the action. A dead path is a lead, not the whole finding: read the sentence around it, since a moved file usually means the claim moved too. Also grep each layer for systems named as retired in the rules (the per-Stop LLM judge, Obsidian, waves, board-runner) still written as live. Every memory file gets a Tier 1 read each pass, flagged or not: a memory about a bug that has since been fixed names only live paths, so skill-drift never flags it (pass 1 found 25 of 38 dotfiles memories stale, most with no dead path).
4. **Fix by cause, one area per PR.** Skills and rules: a branch per area under `~/.worktrees/`, routed by `dotfiles-land`, rule edits through `update-rules`, a skill's `metadata.reviewed` bumped only after checking it. Memory files and anchors: edit in place; delete a memory whose whole fact is a fixed bug and drop its index line.
5. **Lessons: rewrite, never pile up.** A correction chain becomes one entry saying what is true now. The replaced text and any entry about a retired system move to `~/.agent/lessons/_archive/<project>-superseded.md` with a line naming what replaced it; nothing is deleted. Work through the chains `chains.tsv` lists first: each line is a corrector and the exact lesson its `<!-- supersedes:KEY -->` marker names (`lessons key FILE LINE` prints a key), so fold the two, archive the old text and drop the marker; a target of `-` is a marker whose entry was reworded or archived, so re-point it or drop it. Then the "Superseded, for removal" lists dream wrote in `~/.agent/dreams/<project>/DREAMS.md` before it wrote markers, then the dead-path entries `docs.json` lists, at most 40 entries a pass so each one is checked. An entry that only says "correcting" or "SUPERSEDED" with no marker is a lead to read, never proof of a live chain.
6. **Knowledge: fix through its one writer.** Skip this step when another session is restructuring the vault (`git -C ~/.notes status --porcelain knowledge` is dirty, or an item on the knowledge base is running) and say so in the report. Otherwise work `knowledge.json` class by class and change pages only through `notes knowledge apply <ops.json> --retired <retired.tsv>`, never by hand, so the registry, shrink guard and retired check hold. A `retired_host` or `retired_command` line is a fact to retire: say on that line that the thing is sold, retired or replaced (and by what), or drop the claim; apply refuses an op that writes one as live. A `dated_slug` page moves to its undated slug under its registered domain with its links updated; an `unregistered` domain is a `domains.toml` row only when its pages are a real domain, else the pages move.
7. **Re-measure** with the same commands, `wc -c` on the lessons files, `lessons chains | wc -l` and `notes knowledge lint`.
8. **Report** in `~/.agent/plans/dotfiles/docs-cleanup.md` (current pass only; git history in `~/.agent` keeps the old ones) per the method, each fix naming its PR or file, plus archived (count per lessons file). Then close the item per the method.

## Do NOT

- Do not verify a claim against another doc; two docs agreeing is usually a copy.
- Do not delete a lesson or silence a finding with `skill-drift: ignore` to make a number drop; move it to `_archive/` or fix the claim.
- Do not touch auth tokens, history, logs or sqlite state, and do not edit mem0 (its queue stays human-gated).
