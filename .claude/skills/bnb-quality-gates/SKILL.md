---
name: bnb-quality-gates
description: BNB platform monorepo quality rules at /home/kblack0610/dev/bnb/platform — what's enforced (Oxlint, Oxfmt, vitest, syncpack, knip, lint-staged, custom shell checks) and what's NOT enforced (no-floating-promises, eslint-plugin-playwright, jsx-a11y, noUncheckedIndexedAccess), plus the pre-PR checklist and e2e hygiene rules. Use when adding a dependency, opening or reviewing a PR in this repo, debating a new framework or pattern, asking "is this lint rule enabled" or "do we have X check", auditing test/e2e/lint hygiene, or before installing eslint-plugin-* packages. Do NOT suggest installing ESLint or Prettier here — this repo runs Oxlint and Oxfmt by design; ESLint is only an option for rules Oxlint cannot express, and only as a parallel pass.
---

# bnb-quality-gates

Quality enforcement for the BNB platform monorepo at `/home/kblack0610/dev/bnb/platform`. This skill is the source of truth for "what gates run and what gates don't" — read it before recommending a tooling change, opening a PR, or debating whether a rule "should" exist.

## Toolchain choices (and why)

| Concern | Tool | Notes |
|---|---|---|
| Lint | **Oxlint** (Rust) | `.oxlintrc.json` at root; plugins: typescript, react, vitest. Do not propose ESLint as a wholesale replacement. |
| Format | **Oxfmt** (Rust) | Runs via `pnpm format` and lint-staged. No Prettier in this repo. |
| Test runner | **Vitest** | Sharded in CI; no Jest anywhere. |
| Dependency drift | **Syncpack** | `pnpm sync:check` |
| Dead code | **Knip** | `pnpm knip` |
| Pre-commit | **bare git hook** | `scripts/git-hooks/pre-commit` installed by `pnpm prepare` (no Husky). |
| E2E (web) | **Playwright** 1.55+ | `apps/placemyparents/web/playwright.config.ts` with role-based projects, storageState reuse. |
| E2E (mobile) | **Maestro** | `apps/placemyparents/mobile/.maestro/*.yaml` |

**Rule of thumb:** prefer extending Oxlint config over migrating to ESLint. Only reach for ESLint when a rule is genuinely impossible in Oxlint (e.g., `@typescript-eslint/no-floating-promises` requires type information Oxlint doesn't currently consume).

## What's enforced

Run `pnpm lint && pnpm format:check && pnpm typecheck && pnpm test` to clear the local gate. Each maps to:

| Gate | Command | Where it lives |
|---|---|---|
| Lint | `pnpm lint` → `oxlint -c .oxlintrc.json . && bash scripts/check-no-lazy-mutation-cast.sh` | `.oxlintrc.json`, `scripts/check-no-lazy-mutation-cast.sh` |
| Format | `pnpm format` (apply) / `pnpm format:check` (verify) → `oxfmt .` | repo-wide |
| Types | `pnpm typecheck` → `turbo run typecheck` | `packages/config/tsconfig.base.json` (strict; see gaps) |
| Unit tests | `pnpm test` → `turbo run test` (Vitest, sharded in CI) | `vitest.config.ts` per app |
| Dep drift | `pnpm sync:check` (syncpack) | runs in CI |
| Dead code | `pnpm knip` | runs in CI |
| Mobile config | `mobile-check` CI job | Expo config + tsc + tests |
| Security | `pnpm audit --audit-level=high` (informational) | CI `security-audit` job |

**Oxlint rules currently flipped on** (from `.oxlintrc.json`):
- Errors: `no-var`, `no-debugger`, `no-redeclare`
- Warnings: `prefer-const`, `eqeqeq`, `no-unused-vars`, `max-lines: 500`
- `typescript/no-explicit-any`: **off globally** but **error in `apps/placemyparents/**`** (migrations excepted)
- Test files: `vitest/no-focused-tests` **error**, `vitest/no-disabled-tests` **warn**, `vitest/no-identical-title` **error**

**Custom shell gates:**
- `scripts/check-no-lazy-mutation-cast.sh` — runs as part of `pnpm lint`. Add new shell-based checks here rather than spawning new top-level scripts.

**Playwright config** (`apps/placemyparents/web/playwright.config.ts`):
- `forbidOnly: !!process.env.CI` — kills `.only()` in CI
- `retries: 2` in CI, `0` locally
- `expect.timeout: 15000` (CI) / `5000` (local)
- `actionTimeout: 15000`, `navigationTimeout: 45000` (CI) / `30000` (local)
- Setup project pattern with role-based `storageState` reuse

## What's NOT enforced (gap registry)

Track these so you can argue priority before adding a dep or filing a ticket. None of these are wired today.

| Gap | Risk | Why it matters here |
|---|---|---|
| `@typescript-eslint/no-floating-promises` | **High** | Express APIs (`apps/placemyparents/api`, history-time-api, etc.) silently swallow rejections. Highest production-crash risk. Oxlint can't express this — needs type info. |
| `@typescript-eslint/no-misused-promises` | High | Same provenance; passing `async` callbacks where sync is expected. |
| `eslint-plugin-playwright` | Medium | Zero CI enforcement of e2e anti-patterns. The `// e2e-hygiene-disable-next-line no-hardcoded-sleep` suppression comments in `apps/placemyparents/web/tests/e2e/{auth.setup.ts,helpers/auth.helper.ts,helpers/mailpit.helper.ts}` are documentation-only — no linter currently consumes them. |
| `eslint-plugin-jsx-a11y` | Medium | `apps/placemyparents/web` is customer-facing; no a11y lint today. |
| `noUncheckedIndexedAccess` (tsc flag) | Medium | `packages/config/tsconfig.base.json` has it `false`. Flipping it = pure type-safety win, but produces a large diff. |
| `noImplicitOverride` (tsc flag) | Low | Same file. |
| `commitlint` | Low | Conventional commits are convention only. |
| `actions/dependency-review-action` | Low | CI has `pnpm audit` (informational) but no PR-time supply-chain review. |
| `CodeQL` | Low | No SAST. |

When the user asks "should we add X" — find X in this table first. If absent, treat as a new gap and ask whether to add a row.

## Pre-PR checklist

Before opening a PR for review:

```bash
pnpm lint && pnpm format:check && pnpm typecheck
pnpm test --filter=<changed-app>     # or `pnpm test` for monorepo-wide changes
```

Conditional gates:

- **`package.json` touched?** → `pnpm sync:check`
- **Files renamed/deleted?** → `pnpm knip` (dead-code scan)
- **UI change in `apps/placemyparents/{web,mobile}/src/{app,screens,components}/**/*.tsx`?** → e2e spec **and** automated UI walkthrough required (see below)
- **Mobile change?** → run `mobile-check` locally if possible (Expo config + tsc + tests)
- **DB migration added?** → snapshot before, snapshot after; document in PR body

### E2E + walkthrough rule (placemyparents UI)

From `~/.agent/lessons/platform.md` and `~/.claude/projects/-home-kblack0610-dev-bnb-platform/memory/feedback_e2e_and_manual_verification.md`:

Any PR touching `apps/placemyparents/{web,mobile}/src/{app,screens,components}/**/*.tsx` MUST include:

1. A Playwright spec (web) under `apps/placemyparents/web/tests/e2e/` exercising the changed flow, **and/or**
2. A Maestro flow YAML (mobile) under `apps/placemyparents/mobile/.maestro/`, **and**
3. An automated UI walkthrough — Playwright MCP screenshots for web, `adb-ops` captures for Android — attached to the PR body or committed under `docs/runbooks/ui-walkthroughs/{branch}.md`.

Backend-only / types-only / infra-only PRs are exempt — they cannot be e2e-tested directly. If a screen change is genuinely too small to e2e-test (a one-word static-text correction), commit with a `// SKIP: e2e-not-applicable <reason>` marker the Stop hook can grep.

The PR body's test-plan checklist must include the e2e file path and the walkthrough link.

## E2E discipline (placemyparents)

**Anti-patterns to avoid:**

- `page.waitForTimeout(...)` — banned in spirit; current count is **0**, keep it that way.
- Plain `page.waitFor(selector)` — deprecated API; use `waitForSelector` / `waitForURL` / `waitForLoadState` / web-first `expect(locator).toBeVisible()`.
- Bare `setTimeout` in spec files — only allowed for rate-limit (429) backoff, and **must** be marked with `// e2e-hygiene-disable-next-line no-hardcoded-sleep` so the suppression is auditable. Currently used in three places, all backoff-related.
- Hardcoded timeouts ≥ 30s — there is exactly one (`provider-flow.spec.ts:191`); don't add more without a comment explaining why.
- New `test.skip()` / `test.fixme()` without a tracked reason. There are 9 today, all seed-data conditional with inline reasons — they block regression coverage and shouldn't multiply.
- Maestro flows: aggressive `extendedWaitUntil` / `waitForAnimationToEnd` — these add up. Before adding more, see if a `tapOn` with a deterministic wait condition (e.g. visible text) works instead.

**Suppression idiom:** `// e2e-hygiene-disable-next-line <rule-name>` — currently informational. If/when `eslint-plugin-playwright` lands, real rule names will replace `no-hardcoded-sleep` here.

## Before adding a dependency

```bash
# 1. Check the lessons file for prohibitions on this dep / pattern
grep -i '<keyword>' ~/.agent/lessons/platform.md

# 2. Check engines compatibility (Node ≥18, pnpm ≥10 enforced in package.json)
node -v && pnpm -v

# 3. After adding, confirm version drift hasn't broken anything
pnpm sync:check
```

If the lessons file has a rule against the dep / framework / pattern, **stop and discuss with the user** — don't just install it. (Per `~/.claude/CLAUDE.md` workflow rule.)

## Stop hooks & cross-tool rules

- Stop-hook `~/.dotfiles/.config/shared-hooks/pre-stop-checks.sh` includes an `e2e_coverage=PASS|WARN|FAIL` detector that compares screen-file changes against e2e additions and `// SKIP: e2e-not-applicable` markers. A `FAIL` should drive Verification ≤6/10 in session evals regardless of CI status.
- `USER_RULES.md` at the repo root contains MANDATORY workflow rules (PR workflow, never-skip-merge, etc.) — read before any non-trivial task.

## Related

- `/home/kblack0610/dev/bnb/platform/USER_RULES.md` — mandatory PR workflow
- `~/.agent/lessons/platform.md` — accumulated corrections
- `~/.claude/projects/-home-kblack0610-dev-bnb-platform/memory/feedback_e2e_and_manual_verification.md` — e2e + manual verification rule
- `/home/kblack0610/dev/bnb/platform/.oxlintrc.json` — actual lint rules
- `/home/kblack0610/dev/bnb/platform/packages/config/tsconfig.base.json` — actual TS strictness
- `/home/kblack0610/dev/bnb/platform/.github/workflows/ci.yml` — actual CI gates
- `/home/kblack0610/dev/bnb/platform/scripts/git-hooks/pre-commit` — actual pre-commit
