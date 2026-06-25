---
name: bug-bash-wrapup
description: Closes out a bug bash by codifying fixes as automated regression coverage and writing the CHANGELOG section. For every UI/flow fix landed in the bug-bash, drafts a Playwright spec (web) or Maestro flow (mobile) under the project e2e harness, runs it to confirm it catches the regression, then drafts a CHANGELOG Unreleased Fixed block grouping fixes by area with PR citations, and appends durable patterns to ~/.agent/lessons/{project}.md. Use after the bug-bash skill produces a triage doc and Batches A and B are merged. Use when the user says "wrap up the bug bash", "harness + changelog", "close out the bug hunt", or "codify the fixes". Differs from placemyparents-release (release-shaped) and daily:summary (time-window-shaped) — bug-bash-wrapup is workstream-shaped: it consumes a triage doc and produces e2e specs, changelog entries, and lessons updates.
---

# bug-bash-wrapup

Closes the bug-hunt loop. Phases 4–5 of the bug-hunt pipeline (e2e harness + changelog + lessons). Invoked after `bug-bash` has surfaced and fixed bugs. Without an upstream `bug-bash` triage doc this skill has no input.

## When to invoke

- "wrap up the bug bash"
- "harness + changelog for the bug bash"
- "close out the bug hunt on `<repo>`"
- "codify the fixes from `<bug-bash-plan>`"

If invoked without a clear triage-doc input, ask: "which bug-bash plan are we wrapping up?" and offer the most recent plan in `~/.agent/plans/{project}/bug-bash-*.md`.

## Inputs

- **Triage doc** — path to the `bug-bash-{date}.md` plan produced by `bug-bash`
- **Target repo** — same as the bug-bash run
- **PR window** — defaults to "merged since the bug-bash plan was created" (`gh pr list --search "merged:>=YYYY-MM-DD"`)

## Phase 4 — Harness with e2e

Goal: every UI / user-flow fix gets a regression test that would have caught the bug.

### Step 4.1 — Identify which fixes need harnessing

Read the triage doc's findings table. A fix needs a regression test if **any** of:

- It touched `apps/*/web/src/{app,screens,components}/**/*.tsx` (web UI)
- It touched `apps/*/mobile/src/{app,screens,components}/**/*.tsx` (mobile UI)
- It changed an API contract, auth flow, or webhook handler
- The triage row says "Critical" or "High" severity

Skip:

- Backend-only refactors with existing unit-test coverage
- Pure type-only changes
- Doc / comment / lint fixes
- Fixes already covered by an existing e2e spec (verify by running it against the buggy commit)

### Step 4.2 — Choose harness type

| Surface | Tool | Path |
|---|---|---|
| Web UI flow | Playwright | `apps/{app}/web/tests/e2e/<feature>.spec.ts` |
| Mobile UI flow | Maestro | `apps/{app}/mobile/.maestro/<feature>.yaml` |
| API contract | Vitest integration test | `apps/{app}/api/tests/<feature>.test.ts` |
| Auth/session | Playwright (web) + Maestro (mobile) | both |

Reuse existing helpers — for `placemyparents` that means `apps/placemyparents/web/tests/e2e/helpers/` (mailpit, storageState, role fixtures). Do not re-invent helpers.

### Step 4.3 — Draft the spec

Delegate to the `quality-engineer` agent with this prompt shape:

> Given this bug: {symptom from triage row}, evidence at {file:line}, and fix in PR #{N}, write a {Playwright|Maestro} spec under {path} that fails on the parent of PR #{N} and passes on the merge commit. Reuse helpers in {helpers path}. Keep the spec minimal — one happy path + one regression assertion. Follow the e2e hygiene rules in `bnb-quality-gates` (no `page.waitForTimeout`, no plain `page.waitFor`, web-first assertions).

For each generated spec:

1. Write the file via `Edit` / `Write` tool
2. Run the spec against the merge commit: `pnpm e2e --grep "<spec-title>"` (web) or `maestro test <flow.yaml>` (mobile)
3. Confirm it passes
4. **Verification check:** rebase it onto the parent commit (or revert the fix locally) and run again — confirm it **fails**. This proves the spec catches the regression. If it doesn't fail, the spec doesn't actually exercise the bug.
5. Mark the triage row with the spec path

### Step 4.4 — Update e2e suppression registry

If a generated spec needs a hardcoded sleep (e.g., rate-limit backoff), mark it with:

```ts
// e2e-hygiene-disable-next-line no-hardcoded-sleep — {reason}
```

Per `bnb-quality-gates`, these markers are documentation-only today but become real ESLint rules once `eslint-plugin-playwright` lands.

## Phase 5 — Changelog

Goal: a clean `### Fixed` block under `[Unreleased]` that the next release's `placemyparents-release` (or equivalent) will pick up.

### Step 5.1 — Collect PRs

```bash
PLAN_DATE=$(grep -oE '\d{4}-\d{2}-\d{2}' <triage-doc> | head -1)
gh pr list --search "merged:>=$PLAN_DATE" --state merged --limit 50 \
  --json number,title,labels,mergedAt,files \
  --jq '.[] | select(.title | test("bug.?bash|fix"; "i")) | {n: .number, t: .title}'
```

Cross-reference with the triage doc's PR column — every Batch A/B finding should have a PR.

### Step 5.2 — Group by area

Read the existing CHANGELOG to learn the project's section conventions. For `bnb-platform` that's `apps/placemyparents/CHANGELOG.md` with sections by area within `### Fixed` (Auth, Payment, Mobile, etc.).

### Step 5.3 — Draft the entries

For each fix, one line in this shape:

```
- {Area}: {what was broken from the user's POV} (#{PR})
```

Examples:

```
- Auth: Token refresh no longer races on parallel API calls (#1234)
- Payment: Webhook handler now awaits Stripe verification before responding (#1238)
- Mobile: Login screen now clears stale error state when the user retries (#1241)
```

Write under `[Unreleased] ### Fixed` in the appropriate `CHANGELOG.md`. Do **not** promote to a versioned section — that's `placemyparents-release`'s job.

### Step 5.4 — Add a bug-bash backlink

At the end of the `[Unreleased]` block, add a one-liner:

```markdown
*This block includes fixes from bug-bash {YYYY-MM-DD} — see ~/.agent/plans/{project}/bug-bash-{date}.md*
```

This makes the bash discoverable at release time.

### Step 5.5 — Refresh the lab feed

After the CHANGELOG lands, mirror the new status into the **lab project bus** so the
human-facing release/status feed reflects the bash. Deterministic, non-destructive:

```bash
~/.local/bin/agentctl-lab-sync <lab-project>   # e.g. placemyparents; no-op if none exists
```

This refreshes the `## ← Release & status feed` AUTO block in
`~/.notes/lab/projects/current/{name}/summary.md` (latest tag, plans, evals) and never touches
the human `## → For the agents` section. CHANGELOG **prose** stays in the repo (above); the lab
feed just mirrors mechanical state. See the `lab-sync` skill.

## Phase 6 — Lessons

For every finding in Batches A/B:

| Finding root cause | Action |
|---|---|
| Matches an existing lesson | Append a recurrence note (`Recurred {date} via PR #N`) to the lesson body. 3+ recurrences = strengthen the lesson with a more specific rule. |
| Novel pattern | Add a new lesson entry to `~/.agent/lessons/{project}.md` with: symptom, root cause, prevention rule, file paths affected. |
| Tooling gap (linter couldn't catch it) | Add a row to the project's quality-gates skill "What's NOT enforced" table with the new gap + risk level. |

Lessons format (existing convention in `~/.agent/lessons/`):

```markdown
- {YYYY-MM-DD} {symptom} — {root cause}. Prevention: {rule}. Affected: {paths}. PR: #{N}.
```

## Phase 7 — Close the loop

Append a "Results" section to the triage doc:

```markdown
## Results — closed {YYYY-MM-DD}

- Findings closed: N (Batch A: X, Batch B: Y)
- Findings deferred: M (filed as GH issues #aaa, #bbb)
- E2E specs added: K
  - apps/.../web/tests/e2e/foo.spec.ts (covers Finding #1)
  - apps/.../mobile/.maestro/bar.yaml (covers Finding #3)
- Lessons updated: J entries
- CHANGELOG entries: see [Unreleased] ### Fixed in apps/{app}/CHANGELOG.md
- Total PRs: #aaa, #bbb, #ccc
```

Per the global plan-lifecycle rule, the triage doc is the source of truth — edit it in place rather than writing a sibling "results" file.

## Verification

Before reporting wrapup as done:

- [ ] Every Batch A/B finding row in the triage doc has either a PR # + spec path, or a "deferred → issue #" note
- [ ] Every generated spec was run against the merge commit (passes) AND against the parent commit (fails) — both verified
- [ ] CHANGELOG `[Unreleased] ### Fixed` references real PR numbers (cross-check with `gh pr list`)
- [ ] Lessons file has either a recurrence-note or a new-entry for every Batch A/B finding
- [ ] Triage doc has a `## Results` section

## Anti-patterns

- Do not generate a spec without verifying it fails on the buggy parent. A spec that always passes is anti-coverage — worse than no spec.
- Do not promote `[Unreleased]` → `[X.Y.Z]` in this skill. That's release-cutting work — `placemyparents-release` owns it.
- Do not skip Phase 6 lessons. The whole point of the bug bash is to make the next bash find fewer bugs of the same shape.
- Do not over-spec. One regression assertion per fix. If you find yourself writing many assertions, the fix probably needs to be split into separate bashes / fixes.
- Do not use `bug-bash-wrapup` to retro-document fixes that didn't go through `bug-bash`. The triage doc is a required input — without it, prefer `placemyparents-release` (for release prep) or `one-pager` (for ad-hoc post-mortems).

## Related

- `bug-bash` — Phase 1–3, must run first
- `bnb-quality-gates` — e2e hygiene rules + suppression idiom
- `placemyparents-release` — promotes `[Unreleased]` to a versioned release; consumes the CHANGELOG entries this skill writes
- `quality-engineer` agent — delegate for spec strategy
- `gh-workflows` skill — for PR window queries
- `~/.agent/lessons/{project}.md` — appended in Phase 6
