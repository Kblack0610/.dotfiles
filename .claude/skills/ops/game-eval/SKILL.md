---
name: game-eval
description: "Evaluate a game the same way every time, on any engine and platform, in lanes: perf (lag, hitches, low fps, GC, server tick) and look (style, design and look of worlds and UI). One spine of nine steps (report, adapter, rule out the harness, capture against a baseline, localize, generalize to the pattern, repeatable probe, file rows, fix and prove) plus a lane file for each lane's instruments and patterns. Verbs: triage <lane> for a reported problem or a capture/mark file, review <lane> for a whole-game pass. Use when the user says \"it lags here\", \"is it the editor or the game\", \"why is this slow\", \"perf pass\", \"this looks off\", \"review the look of <game>\", \"art/style pass\", \"go through my lag marks\", or after a big content wave. Each game repo keeps one adapter doc (commands, budgets, views, boards); the skill never hardcodes a repo's tools. Not for network feel under load or server capacity (the repo's multiplayer ladder, e.g. load.sh / Edgegap bench), not for functional bugs (bug-bash), not for a whole-repo code health pass (stack-review, which this hands structural findings to), and not for menu-by-menu coverage audits (ui-audit)."
metadata:
  category: ops
  tags: [games, performance, profiling, art-direction, ui, triage]
  reviewed: "2026-10-28"
---

# Game eval

Turns "it lagged here" or "this looks wrong" into numbers or pictures, a named cause, a fix to the pattern behind it, and board rows in one shape. One spine, many lanes: the steps are shared, only the instruments, budgets and probes differ. A new lane (audio, load times, memory, network feel) is one file in `lanes/` plus one section in each repo's adapter doc.

## When to Use

- When the human reports lag, a hitch or low fps somewhere, or hands you capture/mark files.
- When the human says a place, a screen or a whole game looks off, or asks for a style pass.
- When a content wave landed and the game needs a perf or look review.

Not for server capacity or network feel under load (the repo's multiplayer doc), functional bugs (`bug-bash`), whole-repo code health (`stack-review`), or per-screen UI coverage (`ui-audit`).

## Step 0, every verb

1. Read `lanes/<lane>.md` here: its patterns list comes first, before any measuring.
2. Read the repo's adapter doc (`references/adapter-contract.md` says where and what it holds). None yet: write it first, from the contract, in the repo's docs, as its own PR.
3. Read the repo's standards file(s). A finding that breaks a written rule is already half triaged.
4. Check machine holds (`agent-hold list`) before any engine run.

## triage <lane>

1. **Report.** Game, spot, activity, platform and build kind (editor, dev build, release, device), peers and bots, symptom. Take it from the mark file's context line when there is one; ask only for what is missing.
2. **Adapter.** Pull the lane's commands, budgets, baseline spot or reference view, and boards from the adapter doc.
3. **Rule out the harness.** Walk the lane's harness list (editor overhead, window focus, tier, debug state). A harness-only cause gets one low row and stops here.
4. **Capture against a baseline.** Same machine, same build, two runs or two shots a side, against the adapter's budget or reference. Never a single number or a single shot.
5. **Localize.** Use the lane's instruments to name the top 1 to 3 owners, with ms, bytes or the layer that draws it.
6. **Generalize, not patch.** Name the pattern behind each owner (from the lane's list or a new one) and grep every instance across the game and the shared engine code. A pattern with siblings or no owning system is structural: hand it to `stack-review` / `kb-architect` for the shared fix and file one migration row listing every instance. A missing marker, switch or view that made this hard to find is itself a finding.
7. **Repeatable probe.** Add the lane's probe for the spot (a perf test case, a named view) so the fix can be A/B'd and the next regression is caught.
8. **File.** Grep both boards for the same thing first and fold into an existing row. Use the lane's row title, add `#tier/N`, never `#worker/*`. Agent board for agent work; the human sheet only for what only a human can do (playing with capture on, device runs, taste calls).
9. **Fix and prove.** Fix the shared thing first, write the pattern's rule in the repo's standards in the same PR, prove with the lane's before/after, close rows with `--proof pr:N`.

## review <lane>

A whole-game pass, run after a content wave or when triage keeps finding the same pattern. Walk the lane's review list per game, measure or shoot each item against the adapter's budgets and references, and output ranked rows (impact x effort) plus `kb-architect` specs for the structural ones. Same filing rules as triage step 8.

## Do NOT

- Do not measure before reading the lane's patterns: most findings are a known pattern, and the pattern is what gets fixed.
- Do not patch one instance and leave its siblings: file the migration row with every instance.
- Do not compare numbers across machines, builds or loads; frame and CPU numbers only compare like for like.
- Do not judge a look from one shot at one tier, or from an editor state the lane lists as misleading.
- Do not hardcode a repo's commands here; they belong in its adapter doc, and this skill links to it.
- Do not run a player build or heavy capture on a shared workstation without the adapter saying it is allowed.
