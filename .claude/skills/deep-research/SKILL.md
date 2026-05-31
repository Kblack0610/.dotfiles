---
name: deep-research
description: Multi-agent deep-research harness — decompose a question into independent threads, fan out one subagent per thread, collect structured briefs, adversarially verify the load-bearing claims, then synthesize a cited report with a verified/unverified column. Use when the user wants a deep, multi-source, fact-checked answer on a broad or contested question (market analysis, competitive intel, "what should I buy/sell", current-events synthesis). Differs from /sc:research + deep-research-agent (single-agent, in-context multi-hop) — this skill ORCHESTRATES multiple isolated researcher subagents and adds an adversarial verification pass. Differs from Explore agents (codebase search, not web).
---

# deep-research

Orchestrate a fleet of researcher subagents to answer a broad or contested question, then verify the claims that actually drive the decision before trusting them.

Core idea: depth comes from **isolated parallel contexts + an adversarial verify pass**, not from one agent doing many searches in one window. Each thread gets its own clean context (so later threads don't starve), and every load-bearing number is independently challenged before it reaches the report.

## When to invoke
- "deep research X", "fact-checked report on X", "research the market for X"
- Broad questions that split into independent sub-questions (pricing + timing + channels + risk…)
- Contested / competing-claims questions where a single source can't be trusted
- High-stakes decisions where a wrong number is expensive

If the question is underspecified (e.g. "what should I buy" with no budget/use-case/region), ask 2-3 clarifying questions first, then weave the answers into the threads.

Do **not** use for: codebase search (use `Explore`), a single-fact lookup (just search), or a question with one obvious authoritative source.

## Inputs
- **Question** (required) — the refined research question.
- **Depth** (optional) — `quick | standard | deep | exhaustive` (default `standard`). Scales thread count + verify rounds.
- **Save** (optional) — report path. Default `claudedocs/research_{slug}_{YYYY-MM-DD}.md` (matches `/sc:research`).

## The pattern
1. **Clarify & scope** — confirm question, constraints, success criteria. Ask 2-3 questions only if genuinely underspecified.
2. **Decompose** — break into a *small set of independent threads* (one non-overlapping angle each). Name them explicitly. Most important step: bad decomposition = redundant agents.
3. **Fan out** — spawn **one subagent per thread**, in parallel, each with a tight brief and the structured-output contract below. Use `deep-research-agent` as the subagent type; fall back to `general-purpose` if unavailable.
4. **Dedup & gap-check** — collect briefs, merge overlapping claims, list what's missing or contradictory. Spawn a second mini-round only for genuine gaps.
5. **Adversarially verify** — for every **load-bearing claim** (any number/date/fact that changes the answer), spawn a skeptic subagent prompted to *refute* it from independent sources. Tag each `verified | unverified | refuted`.
6. **Synthesize** — cited report: direct answer first, then evidence, with a **verification column** and an explicit "unresolved / low-confidence" section. Never bury uncertainty.

## Depth scaling
| Depth | Threads | Verify | Use |
|---|---|---|---|
| quick | 2-3 | spot-check top 1-2 claims | fast orientation |
| standard | 4-6 | verify all decision-driving claims, 1 skeptic each | default |
| deep | 7-10 | 2-3 skeptics per load-bearing claim, distinct lenses | high-stakes / contested |
| exhaustive | 10+, loop-until-dry | 3+ skeptics + a completeness-critic round | "leave nothing out" |

## Fan-out mechanics
- **Small/standard:** spawn parallel `Agent` calls in a single message (one per thread); synthesize in the main context.
- **Deep/exhaustive, or when verification has structure:** author a **Workflow** script — `pipeline(threads, research, verify)` so each thread's claims verify as soon as its research returns, then synthesize. (Workflow needs explicit user opt-in; invoking this skill for a deep/exhaustive run is that opt-in.)
- Cap concurrency at the runner default; pass all threads — excess queue.

## Structured brief (each researcher returns)
Require each thread agent to return, densely:
- **claims** — each as `{ claim, value, source_url, source_tier, confidence }`
- **source_tier** — `primary` (actual listing/filing/doc fetched) vs `snippet` (search-result summary only)
- **range/curve** where relevant (e.g. price-by-tier), not a single point
- **scam/quality flags** — data that looks contaminated or unreliable
- **could-not-verify** — explicit gaps

Tell the agent its output is *data for an orchestrator, not a user-facing message* — dense and factual.

## Adversarial verification (the differentiator)
- A claim is **load-bearing** if changing it changes the recommendation. Verify those; don't waste skeptics on color.
- Each skeptic is prompted to **refute, defaulting to `refuted=true` if it cannot independently confirm**. Diversity beats redundancy: give skeptics *distinct lenses* (price claim → "find a contradicting sold comp", "is the source primary or a snippet?", "is this a scam/placeholder listing?").
- A claim survives only if a majority of skeptics confirm from independent sources.
- **Snippet-only numbers that drive a decision are `unverified` by default** — say so in the report.

## Primary-source discipline
- Any decision-driving number must trace to a **fetched primary source**, or be flagged `snippet-only`.
- If a site blocks fetch (JS-heavy / anti-bot — e.g. eBay & marketplaces), route through **Playwright MCP** before falling back to snippets. Note in the report when a number is snippet-only because the source was unfetchable.
- Degrade gracefully: if Tavily MCP isn't configured, use built-in `WebSearch`/`WebFetch`.

## Output
Save to the report path and print a tight summary. Structure:
```
# Research: {question}   ({YYYY-MM-DD}, depth={depth})
## Answer            ← conclusion / recommendation first
## Key findings      ← table: claim | value | source | tier | verdict
## Evidence & analysis
## Unresolved / low-confidence   ← never omit
## Method            ← threads run, verify rounds, what was unfetchable
## Sources           ← all URLs
```

## Anti-patterns
- Don't scale agent count for its own sake — **distinct angles**, not "as many as possible". 10 redundant finders < 5 distinct finders + a verify pass.
- Don't let one agent research everything in one context (that's `/sc:research`'s weakness — context starves on later threads).
- Don't present snippet-scraped numbers as verified — the verdict column is the point.
- Don't skip the verify pass on the numbers that drive the decision; that's the one thing this skill exists to add.
- Don't hide contradictions to make the narrative clean (codex `deep-research` guardrail).

## Related
- `deep-research-agent` (Claude agent) — the per-thread researcher; also usable solo for a single-context investigation.
- `/sc:research` — single-agent adaptive research command; this skill is its multi-agent + verify superset.
- `~/.dotfiles/.config/codex/skills/deep-research/SKILL.md` — Codex-side thin methodology (keep conceptually in sync).
- `Explore` agents — codebase (not web) fan-out.
- Workflow tool — orchestration substrate for deep/exhaustive runs.
