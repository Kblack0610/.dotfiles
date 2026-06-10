---
name: prod-smoke-suite
description: PlaceMyParents production regression smoke — the suite-based `scripts/db.sh prod smoke` system that exercises real prod end-to-end (auth, tRPC CRUD, messaging, public reads, billing, file upload, admin, money-config). Use when the user asks to "smoke prod", "verify prod end-to-end", "run the regression smoke", "find broken features on prod", "verify the post-deploy health", or after any production release (placemyparents-release skill). Differs from CI e2e (localhost + fakes — gates merge) — this skill verifies the deployed prod app + infra + real third-party services, catching deploy/config issues unit tests can't reproduce. Differs from sc:manual-test (single-PR walkthrough) — this is whole-app, post-deploy. Suite list lives in `scripts/db-prod.lib.sh`; canonical doc is `docs/operations/DATABASE_RUNBOOK.md`. Repo: `/home/kblack0610/dev/bnb/platform`.
---

# prod-smoke-suite

Drives the BNB-platform `db.sh prod smoke` system — 10 registered suites that hit real prod, find broken features, and clean up after themselves. The script's job is to **find regressions**, not gate merges (CI e2e does that). Run it after every release and any time prod feels off.

## When to invoke

- "smoke prod", "run the prod smoke"
- "is prod actually working?", "verify prod end-to-end after deploy"
- "find any broken features on prod"
- After `placemyparents-release` finishes a tag → manifest → Flux loop
- Before promoting `develop → main` if a backend or infra change is in the window
- When a prod incident report needs evidence of which flows DO work

## Canonical references

| Where | What |
|---|---|
| `scripts/db.sh` | The CLI entry: `./scripts/db.sh prod smoke [flags]` |
| `scripts/db-prod.lib.sh` | Suite implementations, tRPC helpers, cleanup |
| `docs/operations/DATABASE_RUNBOOK.md` § *Prod — regression smoke* | Canonical user-facing reference; this skill is the meta layer |
| `_register_suite ...` lines near the bottom of `db-prod.lib.sh` | Suite catalog — read this first when adding a suite |

This skill must stay consistent with the runbook. When suite counts/scopes change, update both.

## The suite catalog (today: 10 suites)

| Suite | Gate | Flows exercised |
|---|---|---|
| `core` | gate | L0 config (`platform_settings`, `SQUARE_ENVIRONMENT=production`, `MERCURY_API_TOKEN` prefix, key tables) + L1 HTTP baseline. With `--full`: L2 auth, L3 coord, L4 provider, L5 integration. |
| `auth-deep` | gate | login, refresh-tokens, `/me`, forgot-password, send-verification-email, `user.getLinkedProviders`, `user.updateProfile`, `user.deleteMyAccount` |
| `coord-deep` | gate | recipient CRUD (create/list/getById/update/delete) + careRequest CRUD + `careRequest.forRecipient` |
| `provider-deep` | gate | `homecare.update`/`myFacilities`/`delete`; manualResident CRUD; `careRequest.pendingResidencyRequests` + `currentResidents` |
| `messaging` | gate | `message.send` (coord ⇄ provider), `listConversations`, `getConversation`, `markAsRead` |
| `public-reads` | gate | `homecare.list`, `homecare.search` (q + city/state), `homecare.getById`, `referral.list`, `ccld.preview` (warn-only external dep) |
| `billing` | gate | `billing.coordinatorSummary`, `billing.providerSummary`, `payment.getStatus` (fake tx → 4xx), `payout.myPayouts`, `payout.providerBilling` |
| `files` | gate | profile/facility/recipient image upload+delete (REST multipart); physician-report upload+`getDownloadUrl`+`softDelete` (tRPC, behind `PHYSICIAN_REPORTS_ENABLED` flag) |
| `admin` | gate | `adminSettings` list/get/update roundtrip, `user.list` — uses psql role promotion |
| `money-config` | gate | platform-fee + Mercury config state-machine assertions; `EMERGENCY_READONLY` round-trip |

Canonical answer to "what flows do we cover?" is `./scripts/db.sh prod smoke --list` — never type a list from memory.

## How to run

```bash
cd /home/kblack0610/dev/bnb/platform

./scripts/db.sh prod smoke                  # core, L0 + L1 only (read-only)
./scripts/db.sh prod smoke --full           # core + L2–L5 (creates ephemeral users)
./scripts/db.sh prod smoke --suite=<name>   # one suite only (forces full mode for core)
./scripts/db.sh prod smoke --all            # every registered suite
./scripts/db.sh prod smoke --list           # print suite catalog + descriptions
./scripts/db.sh prod smoke --layer=N        # back-compat: legacy layer N inside core
./scripts/db.sh prod smoke --no-config      # skip L0 (no kubectl context)
```

**Post-release default:** `--all`. **Quick "is anything on fire" check:** no flags. **Single-suite debug after a failure:** `--suite=<name>`.

## Pre-flight (must check before running)

| Check | Why | Command |
|---|---|---|
| Repo branch + clean tree | Avoid running stale suite code | `git -C ~/dev/bnb/platform status --short && git -C ~/dev/bnb/platform branch --show-current` |
| `gh auth status` | Some suites cite PRs in their failure reports | `gh auth status` |
| `kubectl` context | L0 reads pod env via `kubectl exec` | `kubectl config current-context` (expect `do-nyc3-placemyparents-k8s-prod`) |
| `jq` installed | Every tRPC helper parses with jq | `command -v jq` |
| Whitelist | Suites call `_psql_prod` which requires the runner's IP whitelisted; the script auto-adds + auto-removes | Handled — but if you see `psql: error: connection ... timed out`, check `./scripts/db.sh prod whitelist` |

## tRPC method routing (load-bearing — most common pitfall)

tRPC enforces HTTP method **by procedure type**:

- **Mutation** → `POST /api/trpc/<proc>` with body `{json: <input>}` → use `_trpc_post`
- **Query** → `GET /api/trpc/<proc>?input=<URL-encoded {json: <input>}>` → use `_trpc_get`

POSTing to a query returns **HTTP 405 METHOD_NOT_SUPPORTED**. When adding a check, look at the procedure's definition in `apps/placemyparents/api/src/trpc/routers/` — `.mutation(...)` vs `.query(...)` determines the helper.

Both helpers unwrap responses with the same chain:

```bash
.result.data.json // .result.data
```

List-shaped responses additionally wrap the array under one of several keys. The robust fallback used inside check functions:

```bash
jq -r '(.items // .docs // .results // .data // .) | length'
```

## Image uploads (the `files` suite)

The server's `validateImageFile` rejects images below **50×50** (`apps/placemyparents/api/src/services/image.service.ts`). Use the 100×100 transparent PNG helper:

```bash
_write_smoke_png   # sets $_SMOKE_PNG to a tempfile (~102 bytes, base64-embedded)
# ... use $_SMOKE_PNG in curl -F file=@$_SMOKE_PNG ...
rm -f "$_SMOKE_PNG"
```

A 1×1 placeholder will fail validation. If the floor changes server-side, update the embedded base64 in `_write_smoke_png`.

Each upload's corresponding `DELETE /api/v1/.../image` removes the DB row, but the underlying Spaces object may persist (the server doesn't currently cascade-delete entity images). Orphan size is tiny (~100 bytes per smoke run) and smoke emails are unique per run, so subsequent runs don't pile up.

## Error visibility (do not swallow stderr)

`_trpc_post` / `_trpc_get` write their HTTP-error log to **stderr** (`>&2`), not stdout, so check functions that capture stdout (most of them, to parse responses) still surface what went wrong on prod. **Do not redirect stderr to `/dev/null` in checks** — the error detail is the entire point of running the smoke. Past instance: a 500 with `column reference "name" is ambiguous` was invisible until stderr was un-swallowed.

## `set -e` interaction (why suites run under `set +e`)

`db.sh` itself runs under `set -euo pipefail`. If a check inside a suite returned non-zero and the suite were also under `set -e`, the first failure would abort the rest of the smoke — defeating the goal of finding **every** broken feature in one pass.

`prod_smoke` saves the caller's `set -e` state, switches to `set +e` for the duration of all suites, and restores on exit. Each check is responsible for its own pass/fail bookkeeping via `_run_check` and the `_PROD_SMOKE_RESULTS` array. Do not add `set -e` inside `_smoke_suite_*` bodies.

## Ephemeral-user safety net (three layers)

Smoke registrations use unique emails matching the pattern `smoke-%@blacknbrownstudios.com`. These are listed in `TEST_EMAIL_PATTERNS` so the prod `clear` command sweeps them by default.

| Layer | When | What |
|---|---|---|
| 1 | end of each check | `_smoke_cleanup <email>` — hard delete of the user + cascaded rows |
| 2 | end of any `--full`/`--all`/`--suite=` run | `_smoke_orphan_cleanup` — sweeps anything layer 1 missed |
| 3 | next `./scripts/db.sh prod clear` | `TEST_EMAIL_PATTERNS` match → swept regardless of when |

This means even a SIGKILL'd smoke run can't leave a permanent footprint on prod.

## Adding a new suite

1. Read the suite registration block near the bottom of `db-prod.lib.sh` to learn the pattern.
2. Define `_smoke_suite_<name>() { ... }` using `_run_check` for individual flows.
3. Pin the procedure's input schema by reading `apps/placemyparents/api/src/trpc/routers/<router>.ts` — do **not** invent input shapes.
4. Call `_register_suite "<name>" _smoke_suite_<name> gate "<one-line description>"` after the function body.
5. Update the suite table in `docs/operations/DATABASE_RUNBOOK.md` and the catalog in this skill.
6. Smoke the new suite against prod once before opening the PR: `./scripts/db.sh prod smoke --suite=<name>`.

If a check legitimately can't gate (e.g., depends on an external service that's flaky and not under our control), register it with `warn` instead of `gate` — failures will log but not flip the overall exit code.

## Hand-off shape

When this skill finishes a smoke run, output:

```
prod smoke {date} — N suites run, M passed, K failed/warn.
Failures:
  - {suite}: {check name} — {one-line symptom}
    {full HTTP error or stderr extract}
Triage: {existing-issue-link OR draft a new ticket via gh-workflows / vikunja MCP}
Next: {suggested fix or follow-up smoke after fix lands}
```

For each new failure, draft a ticket (don't just report) — the smoke surfacing a bug and the bug not being filed is the same as not running it.

## Anti-patterns

- **Do not** redirect `_trpc_post` / `_trpc_get` stderr to `/dev/null`. The HTTP error is the value.
- **Do not** post to a query or get a mutation — HTTP 405 every time. Check the router for `.mutation` vs `.query`.
- **Do not** hardcode a 1×1 PNG for image upload. Use `_write_smoke_png` (50×50 floor).
- **Do not** add `set -e` inside `_smoke_suite_*`. One failing check should not abort the suite.
- **Do not** invent input shapes. Pin them by reading the router source.
- **Do not** skip cleanup in a check that creates a user. Layer 3 (TEST_EMAIL_PATTERNS sweep) is a safety net, not a substitute.
- **Do not** treat `--full` as the default. Default is L0 + L1 only (read-only) — explicit `--full` is the contract that ephemeral users will be created.
- **Do not** point prod smoke at preview by overriding `PROD_API_BASE` (or vice versa) — `_smoke_assert_target` refuses on the API's self-reported `environment` mismatch, by design. The supported preview path is `./scripts/db.sh preview smoke` (added 2026-06-09, PR #760): same suite catalog, `SMOKE_TARGET=preview`, kubectl-exec psql instead of doctl+whitelist, email + money-config warn-only. It's also what `deploy.sh`'s pre-tag preview gate runs (`preview smoke --all`).
- **Do not** assume a "passing" smoke means the app works end-to-end. The smoke covers the registered surface; new flows are uncovered until a suite is added.
- **Do not** edit the suite catalog in this skill without editing `DATABASE_RUNBOOK.md` (and vice versa). Drift is silent and confusing.

## Real prod bugs this system has caught (proof points)

- `forgot-password` and `send-verification-email` → HTTP 504 (mail transport timing out; fixed in #689 via Resend HTTP API)
- `homecare.search` → HTTP 500 `column reference "name" is ambiguous` (unqualified SQL join; fixed in #688 by qualifying with `hcf.` alias)
- Email auth flows fully broken on prod despite green CI e2e (because local CI uses Mailpit fakes — only real-prod smoke catches it)

The pattern: CI tests pass because they use fakes; smoke catches the gap between fake and real. That's the entire reason this skill exists.

## Related

- `placemyparents-release` — calls into this skill as the post-deploy verification step
- `bnb-quality-gates` — lists what's enforced at PR-time; smoke covers what isn't
- `bug-bash` — broader sweep (lint/types/tests/security); smoke is one input among many
- `k8s-ops` — for the `kubectl exec` calls L0 makes against prod pods
- `cloudflare-ops` — if DNS/tunnel suspicions arise from a failing smoke
- `gh-workflows` — for filing tickets against surfaced bugs
- `docs/operations/DATABASE_RUNBOOK.md` — the user-facing canonical reference; this skill is the meta layer
