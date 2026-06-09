---
name: placemyparents-release
description: PlaceMyParents production release runbook — when user says "release vX.Y.Z", "ship placemyparents", "cut a release", or "deploy placemyparents", drives scripts/deploy.sh through CHANGELOG promotion, pre-flight gates, tag push, and post-deploy verification. Covers web/api (DigitalOcean K8s via Flux GitOps) and mobile (TestFlight + Play Store via self-hosted macOS runner).
---

# placemyparents-release

End-to-end runbook for a PlaceMyParents production release. Bundles `scripts/deploy.sh`, the `develop → main` PR chain, and the `placemyparents-v*` / `placemyparents-mobile-v*` tag conventions into one workflow. The `staging` branch was retired in PR #631; pre-prod verification happens on the home-k3s preview env (`placemyparents.blacknbrownstudios.com`), which auto-deploys on every merge to `main`.

Repo: `/home/kblack0610/dev/bnb/platform`

## When to invoke

- "release v1.X.Y", "ship placemyparents", "cut a placemyparents release", "deploy placemyparents to prod"
- After a phase of work merges to develop and a real version is ready to tag
- Hotfix patches (`<bump>=patch`) and mobile-only releases (`<component>=mobile`) use the same skill

## Pre-flight gates

ALL of these must pass before invoking `scripts/deploy.sh`. If any fail, fix first.

| Gate | Check | Command |
|---|---|---|
| Branch | On `develop` | `git -C ~/dev/bnb/platform branch --show-current` |
| Working tree | Clean (no staged or unstaged changes) | `git -C ~/dev/bnb/platform status --short` |
| Up-to-date | `develop` == `origin/develop` | `git -C ~/dev/bnb/platform fetch origin develop && git rev-parse develop origin/develop` |
| CI | Latest develop commit green | `gh run list --branch develop --limit 5 --json status,conclusion,name` |
| E2E coverage | UI-touching PRs in window have e2e + walkthrough evidence | See `~/.claude/projects/-home-kblack0610-dev-bnb-platform/memory/feedback_e2e_and_manual_verification.md` |
| Open blockers | Triage open PMP PRs | `gh pr list --search "placemyparents in:title" --state open --limit 20` — decide which (if any) to land or defer |
| Tools | `jq`, `gh` installed and authed | `command -v jq gh && gh auth status` |

## Step 1 — Reconcile CHANGELOG

`apps/placemyparents/CHANGELOG.md` `[Unreleased]` must capture every PR shipping in this release.

```bash
LAST_TAG=$(git -C ~/dev/bnb/platform tag --list 'placemyparents-v*' | sort -V | tail -1)
echo "Last tag: $LAST_TAG"

# PRs merged since last tag, scoped to placemyparents + shared packages
git -C ~/dev/bnb/platform log "$LAST_TAG..origin/develop" --oneline -- \
  apps/placemyparents/ packages/ | grep -oE '#[0-9]+' | sort -u

# Diff against [Unreleased] in the changelog
grep -oE '#[0-9]+' ~/dev/bnb/platform/apps/placemyparents/CHANGELOG.md | sort -u
```

For each PR # in the git list but not in `[Unreleased]`: add a concise entry under `### Added` / `### Fixed` / `### Changed` / `### Security`. Group by area (auth, payment, mobile, etc.) when natural.

## Step 2 — Decide the bump

| Bump | When to use |
|---|---|
| `patch` | Bug fixes only, no schema/API/UX change. Hotfixes. Example: 1.8.1 → 1.8.2 |
| `minor` | New features, additive schema, backward-compatible API changes, new screens. Example: 1.8.0 → 1.9.0 |
| `major` | Breaking API change, removed deprecated keys, mobile forced-update required. Example: 1.x.x → 2.0.0 |

If unsure: when the user-visible surface changed, it's `minor`. When a documented field/route was removed, it's `major`.

## Step 3 — Promote `[Unreleased]` → `[X.Y.Z]`

In a release-prep PR (separate from the deploy.sh version-bump PR):

```markdown
## [Unreleased]

### Added

(fresh empty skeleton — entries land here as next-cycle PRs merge)

## [X.Y.Z] - YYYY-MM-DD

### Added
- (everything that was previously under [Unreleased] Added)

### Fixed
- (...)

### Changed
- (...)
```

The `[X.Y.Z]` heading goes IMMEDIATELY below the new empty `[Unreleased]`. Date format: `YYYY-MM-DD` per Keep-a-Changelog.

## Step 4 — Release doc

```bash
cp ~/dev/bnb/platform/docs/releases/TEMPLATE.md \
   ~/dev/bnb/platform/docs/releases/placemyparents/vX.Y.Z.md
```

Template sections (must all be filled):

- **Summary:** one-paragraph release goal + audience + type (public launch / minor / patch / internal)
- **Included Changes:** bullets, link PRs (#NNN)
- **Explicitly Excluded:** what was deferred and why
- **Config, Infra, and Data Changes:** new env vars, migrations, secrets, manifest changes
- **Pre-Tag Checklist:** changelog updated / version bumps aligned / required tests passed / deployment notes reviewed / rollback path confirmed
- **Rollout:** numbered steps (merge intended PRs → create+push tag → monitor deployment → run post-release verification)
- **Rollback:** previous version/tag + GitOps or tag-revert steps
- **Post-Release Verification:** health checks, primary user-flow checks, known-risk checks

Commit the release-doc + changelog promotion in the same release-prep PR.

## Step 5 — Run `scripts/deploy.sh`

```bash
cd ~/dev/bnb/platform

# ALWAYS dry-run first — confirms version arithmetic is what you expect
./scripts/deploy.sh <component> <bump> --dry-run

# component = web | mobile | all   (web = web+API)
# bump      = patch | minor | major

# Then for-real
./scripts/deploy.sh all minor
```

The script will:

1. Create branch `release/placemyparents-v{NEW_VERSION}` off develop
2. Bump versions in 4 files: `api/package.json`, `web/package.json`, `mobile/package.json`, `mobile/app.json` (`expo.version`, `expo.ios.buildNumber`, `expo.android.versionCode`)
3. Commit `chore(placemyparents): bump to v{NEW_VERSION}`, push, open PR → develop with auto-merge, **wait** (15-min timeout, 15-sec poll)
4. After merge, open PR develop → main with auto-merge, **wait**
5. Tag from main: `placemyparents-v{NEW_VERSION}` and/or `placemyparents-mobile-v{NEW_VERSION}` (depending on `<component>`)
6. `git push origin <tags>` — triggers the deploy workflows

Total wall-clock: ~25-40 min for `all` (2 PR merges × ~10 min CI each + tag push).

## Tag → workflow map

| Tag pattern | Workflow file | Deploys to | Mechanism |
|---|---|---|---|
| `placemyparents-v*.*.*` | `.github/workflows/deploy-production.yml` | DO K8s prod (`do-nyc3-placemyparents-k8s-prod`, NYC3) | Docker buildx → DO registry → sed `tag:` in `infra/flux/apps/prod/placemyparents/helmrelease-*.yaml` → auto-merge manifest PR to main → backfill to develop → Flux reconciles |
| `placemyparents-mobile-v*.*.*` | `.github/workflows/mobile-local-release.yml` | TestFlight (tester track) + Play Store (internal, `status: completed`, verified via Play Developer API) | Self-hosted macOS runner: `expo prebuild` → iOS `xcodebuild archive` + `xcrun altool` (TestFlight); Android `./gradlew bundleRelease` + `r0adkll/upload-google-play@v1` + `scripts/verify-play-release.mjs` |
| `history-time-v*.*.*`, `dodginballs-v*.*.*`, `pick-a-number-v*.*.*`, `platform-v*.*.*` | Same `deploy-production.yml` | Respective K8s namespaces | Same Flux GitOps pattern |

Slack notification: `#alerts-deployments` posts on success/failure/cancel.

## Step 6 — Verify

```bash
# Watch workflow runs (replace tag with actual)
gh run list --workflow=deploy-production.yml --branch=main --limit 3
gh run list --workflow=mobile-local-release.yml --limit 3

# K8s rollout (use k8s-ops skill or directly)
kubectl --context do-nyc3-placemyparents-k8s-prod -n placemyparents \
  get pods,deployments

kubectl --context do-nyc3-placemyparents-k8s-prod -n placemyparents \
  rollout status deployment/placemyparents-api
kubectl --context do-nyc3-placemyparents-k8s-prod -n placemyparents \
  rollout status deployment/placemyparents-web

# Smoke prod
curl -sI https://placemyparents.com | head -3
curl -s https://api.placemyparents.com/api/v1/health | jq .

# Mobile: check TestFlight + Play Store consoles for the new build (15-30 min ingest)
# Android: do NOT trust `submit-android: success` — the run includes a `Verify Play release went live`
# step that fails the workflow if the AAB ends up as a draft / orphan bundle. If you need to spot-check
# manually:
node scripts/verify-play-release.mjs com.kblack0610.placemyparents internal <versionCode>
```

## Step 7 — Promote Android to the PUBLIC (production) track

**The mobile tag only ships to the `internal` track. It does NOT update the public app.** Skipping this step is what left PlaceMyParents stuck on internal with nothing public since April — internal stays green while the public app silently falls behind. This step is the actual "Android shipped to users" gate.

```bash
# 1. Promote the just-released versionCode internal → production (no rebuild).
#    rollout=1.0 = full; rollout=0.2 = staged 20%. version_code blank = latest on INTERNAL track
#    (Play state is source of truth, NOT app.json — app.json drifts from the real built AAB).
gh workflow run mobile-promote-android.yml -f app=placemyparents -f track=production -f rollout=1.0
gh run watch "$(gh run list --workflow=mobile-promote-android.yml --limit 1 --json databaseId --jq '.[0].databaseId')"

# 2. Confirm the PUBLIC track is live (source of truth — not the internal check above):
node scripts/verify-play-release.mjs com.kblack0610.placemyparents production <versionCode>
#    OK => versionCode N on track 'production' has status 'completed'
```

If Play **Managed publishing** is on, the promote stages the release and a human must click Publish in Play Console → Publishing overview. The weekly `mobile-release-drift.yml` cron is the backstop: it goes red (and opens an issue) whenever production is behind the latest built versionCode.

## Step 8 — Vikunja release coordination ticket

The `platform / Release Management` epic (project id 29) holds one coordination ticket per release.
**This ticket is load-bearing**: `scripts/deploy.sh` refuses to cut a release unless an open
ticket for the target version exists, has no `hold` label, and has every `- [ ]` verification
checklist item ticked. The deploy gate runs as a pre-flight in step 5; if it refuses, the rest of
the deploy never happens.

How the ticket gets there:

- **Auto-created** on the first PR-merge to `develop` after the previous release tag, by
  `.github/workflows/vikunja-close-on-merge.yml`. Title is `placemyparents-v<next-patch>`. Each
  subsequent PR-merge to develop appends a `- PR #N — title` line under "## PRs in batch".
- **preview-smoke green** is auto-ticked by `.github/workflows/preview-smoke.yml` after the
  home-k3s preview env passes its health checks (post-merge to main).
- **Mobile / migration** items are ticked by the deployer when applicable, or removed from the
  checklist if not in scope for this batch.
- **`hold` label** stops the cut. Apply it in Vikunja to pause; remove to proceed.
- **`--no-ticket` escape hatch** on `scripts/deploy.sh` bypasses the gate with an auditable stderr
  warning. Reserved for genuine emergencies when Vikunja is unavailable.

After the deploy workflow is green (post-step 6), close the ticket:

```bash
# Flip done=true + swap In Development → Done + move to Done bucket
# (view id 116, done bucket id 87)
TICKET_ID=$(curl -fsSL -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  "https://vikunja.kblab.me/api/v1/projects/29/tasks?filter=done=false&per_page=50" \
  | jq -r --arg t "placemyparents-v<NEW_VERSION>" '.[] | select(.title==$t) | .id')

# GET → modify → POST full task (partial POST resets fields per the gotcha).
TASK=$(curl -fsSL -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  "https://vikunja.kblab.me/api/v1/tasks/$TICKET_ID")
UPDATED=$(printf '%s' "$TASK" | jq '
  .done = true
  | .done_at = (now | strftime("%Y-%m-%dT%H:%M:%SZ"))
')
curl -fsSL -X POST -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  -H "Content-Type: application/json" -d "$UPDATED" \
  "https://vikunja.kblab.me/api/v1/tasks/$TICKET_ID" >/dev/null

# Swap labels: remove In Development (1), add Done (3).
curl -fsSL -X DELETE -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  "https://vikunja.kblab.me/api/v1/tasks/$TICKET_ID/labels/1" >/dev/null 2>&1 || true
curl -fsSL -X PUT -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  -H "Content-Type: application/json" -d '{"label_id":3}' \
  "https://vikunja.kblab.me/api/v1/tasks/$TICKET_ID/labels" >/dev/null

# Move to Done bucket
curl -s -X POST -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  -H "Content-Type: application/json" \
  -d "{\"task_id\": $TICKET_ID}" \
  "https://vikunja.kblab.me/api/v1/projects/29/views/116/buckets/87/tasks"
```

Reasoning: the per-release coordination ticket is the queryable artifact you'd reach for in a
quarterly review or HIPAA audit — what shipped, in which release, who fixed what. PRs scatter; the
release ticket consolidates. It also now actively prevents accidental / unilateral releases.

## Recipes

```bash
# Web/API + mobile, new feature minor bump
./scripts/deploy.sh all minor

# Web/API patch hotfix only
./scripts/deploy.sh web patch

# Mobile-only patch (no API change)
./scripts/deploy.sh mobile patch

# Major release (breaking API or forced mobile update)
./scripts/deploy.sh all major
```

## Manual fallback — packages already at target version

**Special case:** when `package.json` was bumped to the target version in a previous PR but the tag was never cut. `scripts/deploy.sh` would over-bump (e.g. `minor` on `1.8.0` → `1.9.0`).

```bash
# 1. Land your release-prep PR (CHANGELOG promotion + release doc) to develop normally
# 2. Skip scripts/deploy.sh; do the rest manually:

cd ~/dev/bnb/platform
git fetch origin develop main

# develop → main
gh pr create --base main --head develop \
  --title "release: placemyparents v1.8.0" \
  --body "Release placemyparents v1.8.0. Merging develop into main for deploy."
gh pr merge <main-pr-num> --merge --auto
# wait for merge

# Tag and push from main
git fetch origin main
git tag placemyparents-v1.8.0 origin/main
git tag placemyparents-mobile-v1.8.0 origin/main
git push origin placemyparents-v1.8.0 placemyparents-mobile-v1.8.0
```

## Gotchas

- **Staging branch retired** in PR #631 — flow is `develop → main` directly. Pre-prod verification happens on the home-k3s preview env (`placemyparents.blacknbrownstudios.com`), which auto-deploys on every merge to `main`. The earlier PR #301 staging gate is gone.
- **Mobile `buildNumber` and `versionCode`** are auto-incremented by `scripts/deploy.sh`. They live in `apps/placemyparents/mobile/app.json` (`expo.ios.buildNumber` is a string, `expo.android.versionCode` is an int).
- **HIPAA toggle** `PHYSICIAN_REPORTS_ENABLED` requires DO BAA + private-bucket ACL spot-check before flipping in prod. Currently OFF in v1.8; flip is a v1.9 candidate.
- **Pagination legacy keys** (`docs`, `totalDocs`, ...) cannot be removed until a forced-mobile-update gate ships in v1.9 — see `apps/placemyparents/api/src/utils/pagination.ts`.
- **Wave-number labels** like `(v1.X-N)` in PR titles refer to a refactor wave's step number; they don't necessarily map to the release version. Verify against the actual tag, not the PR title prefix.
- **Pre-flight CI** check is on `develop` HEAD, not on the bump PR. The bump PR runs CI again in the `develop → main` PR step.
- **deploy.sh hard-requires `develop`**, clean tree, up-to-date with origin. It will refuse otherwise.

## Related

- `scripts/deploy.sh` — primary tool (350 LOC)
- `infra/scripts/release.sh` — generic release for non-PMP apps (history-time, dodginballs, pick-a-number)
- `apps/placemyparents/CHANGELOG.md` — Keep-a-Changelog format
- `docs/releases/TEMPLATE.md` + `docs/releases/placemyparents/` — release-doc convention
- `docs/deployment/TAG_BASED_DEPLOYMENTS.md` — Flux GitOps tag mechanics
- `infra/CLAUDE.md` — manual rollback, kubectl emergency commands
- `~/.agent/lessons/bnb-platform.md` — release process lessons (Mailpit/e2e infra, e2e+walkthrough verification rule)
- `~/.claude/projects/-home-kblack0610-dev-bnb-platform/memory/release_workflow.md` and `feedback_release_process.md`
- Sister skills: `gh-workflows` (PR/CI), `k8s-ops` (rollout, contexts), `cloudflare-ops` (DNS smoke if relevant)
