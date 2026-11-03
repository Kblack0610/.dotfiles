---
name: docs-write
description: >-
  Add or change a repo's docs without bloat: edit the one home, link instead of copying, keep the index. Use for "document this", "update the README", "where should this go in the docs". Checking docs against code: docs-audit.
metadata:
  category: authoring
  tags: [docs, documentation, writing, readme, structure]
  reviewed: "2026-11-02"
---

# docs-write

Docs grow by addition: every session adds the paragraph its change needed, with the story of why, and nobody removes the one it replaced. This skill is the procedure for one doc change that leaves the doc no longer than it has to be: in the right home, true now, linked, indexed and inside its budget. The rules themselves live in the repo, never here.

## Scope and triggers

Add or change a repo's documentation the right way, so it does not bloat: find the repo's own doc rules and the one home for the subject, edit that home (a new doc only when nothing covers it), write what is true now with no history, link instead of copying, keep the doc inside its budget, put it in the index, then run the prose check and the repo's doc check. Use whenever a change needs docs: "document this", "write docs for X", "add this to the docs", "update the README", "where should this go in the docs", "write up how X works", or after a feature, fix or harness change whose behaviour a doc describes. Works in any repo; uses the repo's own standard when it has one, and the BNB standard (unity-core docs/writing-docs.md) as the default. Not for checking existing docs against the code (docs-audit), prose voice alone (de-ai-writing, which this skill runs as a step), colleague messages (work-comms), problem briefs (one-pager), or agent rules in CLAUDE.md and AGENTS.md (update-rules).

## When to Use

- A change adds or alters behaviour a doc describes, or a feature, system or fix needs documenting.
- Someone asks where something should be documented, or to update a README or guide.
- A doc grew past its budget in your change and needs trimming or splitting.

Not for auditing whether existing docs match the code (`docs-audit`), or for rules that load into agent sessions (`update-rules`).

## Steps

1. **Read the repo's doc rules before writing.** In order: the repo's `docs/writing-docs.md` or a CLAUDE.md or AGENTS.md section on docs, its one-home table (the playground's is `docs/development/flow.md#one-home-for-each-rule`), and `docs/budgets.txt`. In a BNB game repo the standard is the unity-core pin's `External/unity-core/docs/writing-docs.md`. A repo with no rules of its own still follows the BNB standard (`~/dev/bnb/games/engine/unity-core/docs/writing-docs.md`) as the default.
2. **Find the home.** `git grep -il '<subject>' -- '*.md'` and the one-home table. Edit the doc that already owns the subject. Write a new doc only when none does, and then say in its first line what job it has (a guide, a reference or a design doc).
3. **Write the change as a replacement.** Read the section you are changing and cut what your change made stale in the same edit. State what is true now. A why is one clause plus the PR or test. Name the test class or file instead of describing what each test checks, and link to the config or data file that owns a number instead of copying it. Put the lists in lists or tables. The story of the bug or the incident belongs in the PR body.
4. **Link, do not copy.** When another doc, CLAUDE.md, a skill or a memory needs the fact, it gets one pointer line to the home. When you find a copy of the fact you are changing elsewhere, turn it into a pointer in the same PR.
5. **Index it.** A new doc gets a line in its folder's index or the repo README in the same PR. Before renaming a heading, run `git grep '<file>.md#'`; keep the wording others link to, or fix every link.
6. **Check it.**
   - `python3 ~/.claude/skills/de-ai-writing/scripts/check.py <file>` on each changed doc, and plain ASCII.
   - The repo's doc check: `python3 ci/check-docs.py` in unity-core, `python3 External/unity-core/ci/check-docs.py` in a game repo, or the repo's own test (the playground's `scripts/test/tests/test_one_home.py`).
   - Over a cap: trim the doc, or split it by topic and leave the parent as a short index. After a cut, `--tighten` lowers its budget line.
7. **Land it** the repo's way for a docs-only change (in the playground: Checks, no Unity gate). Put the before and after word counts in the PR body when you cut.

## Do NOT

- Append an "Update:" or dated paragraph under the old one. Replace the old one.
- Raise a cap in `docs/budgets.txt` to make room. Cut instead.
- Restate a rule from its home into CLAUDE.md, a skill, a memory or another doc. Point at it.
- Write the doc as a narrative of what you did this session. A reader needs what is true and where to look.
- Restate these steps' rules in a repo. The repo's standard is the one home; this skill only says how to apply it.
