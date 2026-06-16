---
name: one-pager
description: Generate a concise 1-2 page problem doc in one of three formats — Problem Brief (framing only, ~½ page), One-pager (problem + options + recommendation, default), or Pitch (Shape Up: problem + appetite + solution sketch). Use when the user wants to describe a problem succinctly without a full PRD or tech spec. Saves to ~/.notes/lab/briefs/.
---

# one-pager

Produce a short, focused problem doc and save it to `~/.notes/lab/briefs/`. Three formats are supported; pick one before drafting.

## When to use this skill

- User asks to "describe the problem", "write a one-pager", "draft a brief", "write a pitch", or wants a 1-2 page doc framing an issue or proposal.
- Use this *instead of* `kb-product-owner` (heavy Product Briefs) or `requirements-analyst` (full PRDs) when the user wants something lightweight and domain-neutral.

## Format selection

Pick one of:

| Format | When | Length |
|---|---|---|
| **brief** | Pure problem framing, no solution. Useful early — alignment on *what's wrong* before exploring fixes. | ≤ ~400 words (≈ ½ page) |
| **one-pager** *(default)* | Problem + 2-3 options + recommendation. Useful for decisions and tradeoff conversations. | ≤ ~800 words (1-2 pages) |
| **pitch** | Shape Up style: problem + appetite + solution sketch + rabbit holes + no-gos. Useful when scoping a project. | ≤ ~800 words (1-2 pages) |

**Selecting the format:**
1. If the user passed a format hint as an argument or in their request (`brief`, `one-pager`, `pitch`), use that.
2. Otherwise, ask via `AskUserQuestion` with the three options, defaulting to **one-pager**.
3. Don't ask if the user's intent is obvious from the prompt (e.g., they said "pitch this idea" → pitch).

## Interview

Run the interview corresponding to the selected format. Reuse anything the user already supplied — **don't ask questions whose answers are already on the table**. Keep the interview to 3-5 questions max; use a single `AskUserQuestion` call grouping related questions together where possible. If the user gave enough detail upfront to draft directly, skip the interview entirely and produce a draft, then offer to revise.

### Format: brief — interview

- **Title** (1 line): what should we call this problem?
- **Context** (2-3 sentences): the surrounding situation — what's been happening, what's been tried.
- **Problem statement** (1-2 sentences): the specific thing that's broken / suboptimal.
- **Who's affected**: which users, systems, or workflows?
- **Why now**: what triggered surfacing this? (deadline, incident, new info)
- **Success signals**: how would we know it's resolved? (no solution required — just signals)

### Format: one-pager — interview

- **Title**.
- **Context** (3-4 sentences): background, what's been tried, current state.
- **Problem** (1-2 sentences).
- **Options**: 2-3 distinct approaches the user is weighing. For each: 1-line description + main tradeoff.
- **Recommendation** (optional at draft time): which option, and why. If user has no recommendation yet, leave a `> _TBD_` placeholder.
- **Risks / open questions**: what could go wrong, what's still unknown.

### Format: pitch — interview

- **Title**.
- **Problem** (3-4 sentences): the raw situation, ideally with a real example or anecdote.
- **Appetite**: how much time/effort is this worth? (e.g., "small batch — 2 weeks", "big batch — 6 weeks"). Pitches are scoped *to* an appetite, not the reverse.
- **Solution sketch** (3-5 sentences + optional fat-marker sketch in ASCII or a bulleted flow): rough shape of the approach, not a spec.
- **Rabbit holes**: parts of the problem we're explicitly *not* solving, or known-hard areas to avoid spiraling on.
- **No-gos**: things this proposal will *not* do (cuts scope explicitly).

## Output

Render the chosen template with the answers, then save to:

```
~/.notes/lab/briefs/YYYY-MM-DD-{slug}.md
```

- `YYYY-MM-DD` = today's date (the `currentDate` value in your context).
- `{slug}` = lowercase, hyphenated, derived from the title. Strip punctuation; keep ≤ 6 words. Example: title "Hyprland modular split" → slug `hyprland-modular-split`.
- Create `~/.notes/lab/briefs/` if it doesn't exist (`mkdir -p`).
- If a file with the same name already exists, append `-2`, `-3`, etc. — never overwrite.

After writing, print:
1. The full path of the saved file.
2. The first ~10 lines as a preview.

## Templates

### Template: brief

```markdown
# {{title}}

> Problem brief — {{YYYY-MM-DD}}

## Context

{{context}}

## Problem

{{problem statement}}

## Who's affected

{{affected users/systems}}

## Why now

{{trigger}}

## Success signals

{{how we'd know it's resolved}}
```

### Template: one-pager

```markdown
# {{title}}

> One-pager — {{YYYY-MM-DD}}

## Context

{{context}}

## Problem

{{problem statement}}

## Options

### Option 1 — {{name}}
{{1-line description}}
**Tradeoff:** {{main tradeoff}}

### Option 2 — {{name}}
{{1-line description}}
**Tradeoff:** {{main tradeoff}}

### Option 3 — {{name}}  (omit if only 2 options)
{{1-line description}}
**Tradeoff:** {{main tradeoff}}

## Recommendation

{{which option + why, or `> _TBD_`}}

## Risks / open questions

- {{risk or unknown}}
- {{risk or unknown}}
```

### Template: pitch

```markdown
# {{title}}

> Pitch — {{YYYY-MM-DD}}  ·  Appetite: {{appetite}}

## Problem

{{raw situation, ideally with an anecdote}}

## Appetite

{{small batch / big batch / Nd / Nw}}

## Solution

{{rough shape — 3-5 sentences. Add a bulleted flow or ASCII sketch if it clarifies.}}

## Rabbit holes

- {{thing we're not solving / known hard area to avoid}}
- {{...}}

## No-gos

- {{explicit out-of-scope item}}
- {{...}}
```

## Conventions

- One H1 only (the title); section headings are H2.
- Keep total length within the budget for the chosen format. Cut filler before adding length.
- Don't pad — if a section has nothing real to say, omit it rather than writing "N/A".
- Plain markdown, no fancy formatting (no admonitions, no nested tables).
- Don't auto-promote a brief into a `~/.agent/plans/{project}/` plan — that's a separate, deliberate step the user will trigger.

## Related

- `kb-product-owner` agent (Paige) — use for full Product Briefs with user stories + acceptance criteria.
- `requirements-analyst` agent — use for comprehensive PRDs.
- `kb-architect` agent — use for technical specs and ADRs.
- `~/.notes/lab/HANDBOOK.md` — incubator conventions.
- `~/.notes/lab/ideas/_IDEAS.md` — raw idea capture (free-form, predates this skill).
