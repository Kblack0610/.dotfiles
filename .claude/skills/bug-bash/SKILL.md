---
name: bug-bash
description: Per-feature or per-release bug hunt orchestrator. Sweeps a target repo for bugs (lint, types, tests, deps, dead-code, security, lessons-known patterns, open PR review comments, CI history), produces a triaged plan at ~/.agent/plans/{project}/bug-bash-{date}.md, then dispatches fixes through kb-developer or my:fix-ci with sc:manual-test verification per fix. Use when the user says "start a bug bash on X", "hunt bugs in Y", "let's do a bug bash before the release", or after a feature lands and you want to surface latent issues. Pairs with bug-bash-wrapup for the e2e harness + changelog phase. Differs from daily:analysis (which is a daily sweep) and sc:analyze (single-domain analysis) — bug-bash is workstream-shaped: scoped to a target, produces a triage plan, dispatches fixes, hands off to manual verification.
---

# bug-bash

Workstream orchestrator for hunting and fixing bugs in a target repo. Phases 1–3 of the bug-hunt pipeline (sweep → triage → fix → manual-verify). For phases 4–5 (e2e harness + changelog), hand off to `bug-bash-wrapup` after this skill closes.

## When to invoke

- "start a bug bash on `<repo>`"
- "hunt bugs in `<repo>`"
- "let's do a bug bash before cutting `<release>`"
- After a major feature merges and you want to flush latent issues
- Before promoting `develop → main` for any monorepo

If the user says "find bugs" without a target, ask which repo before starting.

## Inputs

- **Target repo** (required) — full path, e.g. `/home/kblack0610/dev/bnb/platform`
- **Scope** (optional) — `recent` (since last tag/merge), `feature:<branch>`, or `full` (default: `recent`)
- **Project key** — resolved via `~/.dotfiles/.config/shared-hooks/project-map.json` (used for `~/.agent/plans/{project}/` and `~/.agent/lessons/{project}.md` paths)

## Phase 1 — Inventory the target

Before any sweep, gather the rules-of-the-road:

1. **Read the project's quality-gates skill if one exists** (e.g., `bnb-quality-gates` for `bnb-platform`). Treat its "what's enforced" table as the gate inventory and its "what's NOT enforced" table as the latent-bug surface.
2. **Read `~/.agent/lessons/{project}.md`** — this is the bug-pattern catalog. Every lesson is a heuristic: grep for its symptom in the codebase.
3. **Read `USER_RULES.md` or equivalent** at the repo root if present.
4. **Identify the toolchain** — package manager (`pnpm`, `npm`, `bun`), test runner (`vitest`, `jest`), e2e (`playwright`, `maestro`, `cypress`).

## Phase 2 — Sweep (parallel)

Delegate to Explore agents (up to 3 in parallel) for these sweep buckets:

| Bucket | Source of truth | Command shape |
|---|---|---|
| Static analysis | Project lint + types | `pnpm lint`, `pnpm typecheck`, `pnpm format:check` |
| Test failures | Project unit + integration | `pnpm test --reporter=verbose` |
| Dep drift / dead code | Syncpack + Knip if installed | `pnpm sync:check`, `pnpm knip` |
| Security | `pnpm audit`, `security-engineer` agent | `pnpm audit --audit-level=high` |
| Lessons-pattern recurrence | `~/.agent/lessons/{project}.md` | grep each lesson's symptom keywords across repo |
| Open review comments | GitHub via `gh-workflows` skill | `gh pr list --state open` then `gh api repos/.../comments` |
| CI failure history | `gh run list` last ~30 runs | look for flaky specs, recurring infra failures |
| Behavioral risk | `sc:analyze` on changed areas | scoped to recent diff |

**Output:** a raw findings list with file:line evidence for each item. Do **not** fix anything yet.

**Important:** if `bnb-quality-gates` (or equivalent) lists a gate as "NOT enforced" and the sweep finds violations of that pattern, file them as findings even though no linter caught them.

## Phase 3 — Triage doc

Write `~/.agent/plans/{project}/bug-bash-{YYYY-MM-DD}.md` with this structure:

```markdown
# Bug Bash — {project} — {YYYY-MM-DD}

## Context
- Target: {repo path}
- Scope: {recent | feature:X | full}
- Trigger: {why now}

## Findings

| # | Severity | Area | Complexity | Symptom | Evidence | Batch |
|---|---|---|---|---|---|---|
| 1 | Critical | auth | M | Token refresh races on parallel calls | apps/.../auth.ts:142 | A |
| 2 | High | payment | S | Floating promise in webhook handler | apps/.../webhook.ts:78 | A |
| ... |

## Batches

### Batch A — must fix this cycle
- #1, #2, ...

### Batch B — should fix this cycle
- ...

### Batch C — defer / file as issue
- ...

## Per-finding detail

### Finding #1: {short title}
- **Symptom:** ...
- **Evidence:** `file:line`, log/test output snippet
- **Proposed fix:** ...
- **Manual-test plan:** what `sc:manual-test` should verify
- **Lesson reference:** {existing lesson it matches, if any}
```

**Severity rubric:**
- Critical: data loss, auth bypass, payment incorrect, prod outage
- High: silent failure, broken user flow, regression in tested behavior
- Medium: UX papercut, performance issue, missing test coverage
- Low: lint warning, doc drift, cosmetic

**Complexity rubric:**
- Trivial: ≤5 lines, no review needed beyond CI
- S: ≤50 lines, one file, obvious fix
- M: multi-file or refactor, design decision involved
- L: requires its own plan + spec; consider spinning out via `kb-product-owner`

Mirror the **Batch A–E** structure from `~/.agent/plans/dotfiles/2026-04-30-*` schema-drift plans if the find list is large.

## Phase 4 — Dispatch fixes

For each finding in selected batches, in batch order:

| Fix shape | Delegate to |
|---|---|
| Trivial / S, no design call | direct edit |
| M, requires investigation | `root-cause-analyst` agent first, then direct edit or `kb-developer` |
| L, requires spec | `kb-product-owner` → `kb-architect` → `kb-developer` (i.e., kick to `/kb:implement`) |
| Lint / format / CI infra | `my:fix-ci` skill |
| Security finding | `security-engineer` agent |
| Test gap (no behavior change) | `quality-engineer` agent |

After each fix:

1. **Manual smoke** — for any UI / user-flow change, invoke `sc:manual-test` (Playwright MCP for web, `adb-ops` for Android). Capture pass/fail.
2. **Update the triage doc** — mark the finding row with PR # and verification status.
3. **Lesson check** — if the root cause matches an existing lesson, note recurrence in the lesson body. If novel, draft a new lesson entry but do not commit it yet (`bug-bash-wrapup` collects all of them at the end).

## Phase 5 — Hand off

When Batches A and B are clear (or user opts to stop), output a one-paragraph status:

```
Bug bash {project} {date} — N findings, M fixed, K deferred to issues.
PRs: #aaa, #bbb, #ccc
Triage doc: ~/.agent/plans/{project}/bug-bash-{date}.md
Next step: invoke `bug-bash-wrapup` to harness + changelog.
```

Do **not** write the CHANGELOG or generate e2e specs in this skill. That's `bug-bash-wrapup`.

## Anti-patterns

- Do not fix bugs during Phase 2 sweep. Surface first, triage second, fix third — mixing them loses the inventory.
- Do not use `bug-bash` for a single bug. For one bug, just fix it (per CLAUDE.md "Autonomous Bug Fixing").
- Do not run `bug-bash` without reading the project's lessons file. Most "new findings" are recurrences of patterns already documented.
- Do not skip manual smoke for UI changes — the BNB lesson (2026-04-27) makes this mandatory: lint+types+CI passing ≠ feature works.
- Do not auto-edit auth tokens, history files, sqlite databases, or other ephemeral runtime state surfaced by the sweep (per global CLAUDE.md auth-state safety rule).

## Reference targets

- `bnb-platform` (`/home/kblack0610/dev/bnb/platform`) — primary test target; rich lessons file; gates documented in `bnb-quality-gates` skill.
- `placemyparents` (`apps/placemyparents/{web,mobile}` inside bnb-platform) — schema-drift plan in `~/.agent/plans/dotfiles/` is the canonical triage-doc shape to mirror.

## Related

- `bug-bash-wrapup` — Phase 4–5 (e2e harness + changelog), invoke after this closes
- `bnb-quality-gates` — gate inventory for the BNB monorepo
- `daily:analysis` — daily-cadence sweep; bug-bash is the per-workstream sibling
- `sc:analyze` — single-domain code analysis (security/perf/quality/architecture); bug-bash composes it
- `sc:manual-test` — invoked per fix during Phase 4
- `my:fix-ci` — invoked for CI-shaped findings
- `kb-developer`, `quality-engineer`, `root-cause-analyst`, `security-engineer` — delegate agents
- `~/.agent/lessons/{project}.md` — pattern catalog (read before sweeping, append after wrapup)
