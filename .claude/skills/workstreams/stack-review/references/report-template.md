# stack-review report template

Copy to `~/.agent/evals/{project}/stack-review-<YYYY-MM-DD>/report.md`. Plain ASCII. One finding per table row. Use the repo's own names for things.

```markdown
# Stack review: <repo> @ <short sha> (<YYYY-MM-DD>)

## Fingerprint
- Languages and sizes: <lang LOC, ...>
- Build / package: <tools>
- Gates: <what blocks> | advisory: <what only reports> | missing: <what is absent>
- Hot paths: <named list, one clause each on how often they run>
- Rules read: <CLAUDE.md, lessons, gate skill> - constraints that shaped this review: <...>

## Summary
<3-5 lines: the single most important fix, the theme across findings, and counts: N findings, X verified / Y unverified / Z contradicted.>

## Tier 1 - Broken now
| # | Finding | Where | Why it matters | Fix | Effort | Verdict | Safe? |
|---|---|---|---|---|---|---|---|

## Tier 2 - Hot-path performance
(same columns; Verdict cites the measurement and the load average, e.g. "verified: N ms median of 10 runs on a copy, load 2.1")

## Tier 3 - DRY / one source of truth
(same columns; say whether each cluster has already drifted)

## Tier 4 - Structure for scaling
(same columns)

## Tier 5 - Gates
(same columns)

## Leave alone (and why)
- <thing>: <why not now, and what would change that>

## Contradicted
- <claim>: <what the first-hand check showed>

## Next
- fix: <safe-tier rows, grouped into PRs>
- plan: <rows for the board / kb-architect>
```
