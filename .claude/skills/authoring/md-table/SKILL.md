---
name: md-table
description: Write markdown tables in the house style - the compact `| A | B |` over `|---|---|` shape, plain ASCII inside cells, one physical line per row, every row carrying the header's cell count, and a literal pipe escaped as \| even inside backticks. Use when writing or repairing a table in any markdown (docs, READMEs, PR bodies, ticket comments, plans, notes), or when the user says "fix the tables", "the table renders wrong", "the columns are off", or "make the tables consistent". The short version of these rules is always on via the Writing Style rule in CLAUDE.md; this skill is the detail behind it, including the failure modes that still render and so survive a visual check. Not for general prose style (that is the same Writing Style rule), slide tables (marp-slide), or boxes-and-arrows diagrams (svg-diagram).
metadata:
  category: authoring
  tags: [markdown, docs, tables]
  reviewed: "2026-08-13"
---

# md-table

Markdown tables fail quietly. A row with the wrong cell count still renders, just with a column silently dropped. An audit of 1,475 tables in this corpus found the mechanics nearly perfect (zero bad separator rows) and the content rules broadly ignored: 1,285 rows carried non-ASCII glyphs and 21 rows disagreed with their header. The defects that matter are the ones a rendered preview will not show you.

## When to use this skill

- Writing or editing markdown that contains a table, and you want it right the first time.
- The user says "fix the tables", "the table renders wrong", "the columns are off", or "make the tables consistent".

## The canonical shape

```markdown
| Part | Sections | What |
|---|---|---|
| I Foundations | 1-4 | System in one page, both ADRs |
| II Knowledge | 5-11 | The core, and the part most misread |
```

Single space padding inside cells. Compact `|---|` separators: no alignment colons, no padding to column width, no aligning pipes into a grid. Alignment is churn - the next edit reflows the block and the diff becomes unreadable.

## The traps that actually bite

- **Backticks do not protect a pipe.** `` `{mode:"on"|"off"}` `` in a cell adds a column; the row renders, shifted. Escape it as `\|`. This one bug caused most of the mismatched rows in the corpus.
- **Plain ASCII applies inside cells too.** This is where the rule gets dropped: em dashes, arrows, check marks and emoji sail into tables that would never carry them in prose. By far the most-violated rule here.
- **Blank line above and below.** A table glued to the paragraph above folds into it in strict parsers.
- **A cell holds one short phrase.** No lists, no `<br>`, no fenced code, no hard line break. If a cell wants those, the table is the wrong container - use headings. A table needing `<br>` was always prose.
- **One physical line per row.** Never hard-wrap a row; renderers soft-wrap and a source newline becomes a forced break.

## Do NOT

- Do not trust a rendered preview to catch a dropped cell. It renders fine; that is the whole problem. Count cells against the header.
- Do not bulk-reformat tables you did not otherwise touch. Fix-forward on new and edited docs; a mechanical sweep buries the real diff.
- Do not reach for a table when the content is a list of paragraphs. Two columns of prose is a worse list.

## Related

- Writing Style in `~/.claude/CLAUDE.md` and `rulesync-global/.rulesync/rules/overview.md` - the always-on rule this expands.
- `marp-slide` - slide-scoped table guidance. `svg-diagram` - when it is really a diagram.
- `update-rules` - to change the always-on rule layer itself.
