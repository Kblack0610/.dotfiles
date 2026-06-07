---
name: ui-audit
description: Per-app UI/UX audit orchestrator. Generates a code-derived screen inventory (web routes + mobile screens), builds a coverage matrix, drives a wave-by-wave role-sessioned walkthrough (Playwright MCP for web, adb-ops for mobile), captures every screen × viewport with a 9-point design checklist, writes findings.md with severity-coded entries + evidence paths, and hands a triage doc off to ticketing (Vikunja/Jira) and the bug-bash skill for fixes. Use when the user says "audit every screen", "do a full UI/UX audit", "run-pass audit", "find padding issues across the app", or "I want a coverage-guaranteed sweep". Artifacts always live OUTSIDE the repo at `~/.agent/evals/{project}/ui-audit-{date}/`. Differs from bug-bash (broader sweep — lint/types/tests/deps/security; this skill is UI-only and coverage-guaranteed) and sc:manual-test (single PR/feature verification; this skill audits the whole app). Pairs with bug-bash (consumes this findings.md) and bug-bash-wrapup (writes regression specs from the resolved findings).
---

# ui-audit

Workstream orchestrator for a coverage-guaranteed UI/UX audit of a target app. Walks every screen × viewport, scores each against a 9-point checklist, records findings with evidence, and hands off to ticketing + bug-bash. Does **not** fix bugs — that's `bug-bash` (Batch A) and `bug-bash-wrapup` (regression specs).

## When to invoke

- "audit every screen of `<app>`"
- "run a full UI/UX audit on `<app>` — web and mobile"
- "I'm seeing padding/errors all over the app, sweep it"
- "coverage-guaranteed UI sweep before the release"
- After a major feature lands and you want a holistic design pass

Do **not** invoke for a single screen — that's `sc:manual-test`. Do **not** invoke for backend/API correctness — that's `bug-bash`.

## Inputs

- **Target app** (required) — repo path + app subfolder, e.g. `/home/kblack0610/dev/bnb/platform` + `apps/placemyparents/{web,mobile}`
- **Project key** — resolved via `~/.dotfiles/.config/shared-hooks/project-map.json` (used for `~/.agent/evals/{project}/` artifacts path)
- **Audit date** — `YYYY-MM-DD`; if omitted, today

## Where artifacts live (load-bearing)

```
~/.agent/evals/{project}/ui-audit-{YYYY-MM-DD}/
├── matrix.md           # coverage matrix — every screen × viewport row
├── findings.md         # one entry per finding, severity-coded
├── w{1..N}-{route}-{viewport}.png        # screenshots
├── w{1..N}-{route}-{viewport}-fixed.png  # post-fix re-shots (added during cleanup)
└── mobile-{screen}-{theme}.png           # mobile captures
```

**Never** write artifacts inside the target repo. The `~/.agent/evals/` path is the canonical location — it survives `git clean`, isn't accidentally `.gitignore`d, and is greppable across audits. The user has corrected this before; respect it.

## Phase 1 — Inventory (code-derived, not guessed)

Generate the screen list **from the codebase**, not from memory. Two greps per surface:

### Web (Next.js app router)
```bash
find apps/{app}/web/src/app -name 'page.tsx' \
  | sed 's|apps/{app}/web/src/app||;s|/page.tsx||;s|^$|/|' \
  | sort -u
```

### Mobile (React Native screens)
```bash
ls apps/{app}/mobile/src/screens/ \
  | grep -E '\.(tsx|ts)$' \
  | sed 's|\.tsx\?$||' \
  | sort -u
```

Group web routes into **role waves** so the walkthrough only logs in/out N times instead of per-route:

| Wave | Routes |
|---|---|
| W1 | public (`/`, `/about`, `/contact`, `/facilities`, `/facility/[id]`, legal) + auth (`/login`, `/register`, `/forgot-password`, `/reset-password`, `/verify-email`) |
| W2 | coordinator role (dashboard, billing, recipients, care-requests) |
| W3 | provider role (dashboard, facilities, residents, payouts, billing) |
| W4 | shared (messages, profile, settings, admin) |
| W5 | mobile auth + coordinator (light + dark themes) |
| W6 | mobile provider + shared (light + dark themes) |

If the app has different role/segment structure, adapt the wave split — but every wave must be **one role + one browser session** so cookies/tokens don't churn.

## Phase 2 — Coverage matrix

Write `matrix.md` with one row per `(route, viewport)` pair:

```markdown
# UI Audit Coverage Matrix — {YYYY-MM-DD}

Mark each row when audited: `[x] route | viewports done | artifacts | finding-ids or "clean"`.
Web = 1280w + 390w. Mobile = light + dark.

## Web (N) — http://localhost:{port}
### W1 public + auth (M)
- [ ] /
- [ ] /about
...
### W2 coordinator (M) — {seeded-email}
- [ ] /dashboard (as coordinator)
...
```

Each row gets checked off **only** after both viewports have screenshots saved AND the row is annotated with finding IDs (or "clean").

### The coverage guarantee

`grep -c '^- \[x\]' matrix.md` must equal the total row count at handoff. If a row can't be audited (route requires data we don't have, behind a feature flag), mark it `[N/A]` with a reason — never silently skip.

## Phase 3 — Harness setup

| Surface | Requirement | Skill / tool |
|---|---|---|
| Web | Dev server up on a known port; State/Seed API to reset+seed deterministic data | repo-local `pnpm dev --filter=...` + `POST /api/test/reset` |
| Web auth | Seeded role-specific accounts (coordinator + provider; provider with payouts enabled if applicable) | seed script in `apps/{app}/api/src/database/seed*.ts` |
| Web driver | Playwright MCP (must already be connected) | — |
| Mobile | Booted emulator + dev build installed; `adb reverse` to local API | `adb-ops` skill |
| Watchdog | Dev-server crash recovery (the Next.js worker has been observed to die mid-audit) | bash watchdog (see Pitfalls) |

### Watchdog pattern (Next.js sometimes crashes mid-audit)

```bash
(while sleep 30; do
   curl -sS -m 5 -o /dev/null -w '%{http_code}' http://localhost:{port} \
     | grep -q '^200$' \
     || (echo "$(date -Iseconds) web down — restarting" >> /tmp/{app}-watchdog.log
         cd {repo}/apps/{app}/web && nohup pnpm run dev >/tmp/{app}-web.log 2>&1 &)
done) &
```

If the dev server crashes with `Cannot find module '.../next/dist/bin/next'` (broken symlink from a stale `pnpm install`), the fix is `pnpm install --prefer-offline` from the monorepo root, not deleting/re-cloning.

### Local stack bring-up (preferred over preview env)

```bash
docker-compose -f infra/.../docker-compose.yml up -d {app}-postgres
pnpm dev --filter={app}-api --filter={app}-web &
curl -sS -X POST http://localhost:{api-port}/api/test/reset
pnpm --filter={app}-api seed:realistic
```

Preview env is the fallback if local stack won't come up. Note in the matrix which env was used — preview seed data drifts from local seed data and that changes finding interpretation.

## Phase 4 — Wave walkthrough

Each wave is **one agent invocation**, scoped to one role-session, with a single browser context. Per route × viewport:

1. Navigate, wait for network-idle.
2. Capture: `screenshot fullPage=true`, browser console errors, failed network requests, a11y snapshot.
3. Exercise key interactions (the 9-point checklist below):
   - Submit empty form to test validation visibility.
   - Open the most-used modal/dialog.
   - Trigger empty + error states (seed manipulation or invalid input).
4. Score against the 9-point checklist; record findings with file/component evidence.
5. Append row to matrix.md (check the box, list artifacts + finding IDs).

### The 9-point checklist (score per screen)

| # | Category | Rule |
|---|---|---|
| 1 | Spacing/padding | Consistent with the design-token scale (e.g., Tailwind preset); no cramped or overflowing containers; list-item rhythm; safe-area insets on mobile. |
| 2 | Layout | Alignment; truncation/wrapping of long content; responsive behavior at the small breakpoint (390w web, narrow phones mobile); no horizontal scroll. |
| 3 | Typography | Hierarchy; sizes from tokens; no orphan styles or duplicate `<h1>`. |
| 4 | Color/contrast | WCAG AA vs theme tokens; dark-mode parity (mobile). |
| 5 | States | Loading (no flash/jank); empty (helpful, not blank); error (visible message, not swallowed); success feedback. |
| 6 | Interactivity | Dead buttons; double-submit guard; touch targets ≥44px on mobile; form validation visible + scroll-to-error. |
| 7 | Console/runtime | Zero console errors; zero failed requests (web). Zero logcat errors on the screen-under-test (mobile). |
| 8 | Copy | Typos; label consistency (Email vs Mail); branded support addresses (not a personal `@gmail.com`); no leftover dev affordances in prod. |
| 9 | A11y | Roles/labels on interactive elements; `<label for>` ↔ `<input id>` association; aria-live on alerts; alt text. |

### Findings format

Append to `findings.md`. One entry per finding cluster (group by root-cause, not per screen):

```markdown
### W{wave}-{NN} | {route(s)} | {viewport(s)} | {checklist-category} | P{0..3}
{2–4 sentence description}: what's wrong, where, why it matters. Evidence: {artifact-path}, {DOM-snapshot-ref-if-relevant}.
```

Severity rubric:
- **P0** — broken auth/payment, data-loss, prod outage symptom, env that blocks further audit
- **P1** — silent failure of a primary user action; broken responsive layout on a critical screen; PII/branding leak
- **P2** — visible UX papercut; missing state; a11y gap that affects a screen-reader user
- **P3** — cosmetic; copy nit; visual rhythm

When a finding spans many routes (e.g., one shared header is broken on 20 dashboard routes), file **one** finding for the cluster, not 20 — the cleanup PR will be one fix.

## Phase 5 — Resolve loop (during/after Batch A cleanup)

When a fix PR lands that closes a finding, **edit the entry in place** — do not delete it:

```markdown
### W1-01 | /contact | both | 8 copy | P1
Public support contact is a developer's personal Gmail... Evidence: w1-contact-1280.png.
RESOLVED in #690 (Batch A2) — swapped to support@{project}.com. Fixed screenshot: w1-contact-1280-fixed.png. Follow-up: confirm MX/forwarding.
```

This keeps the audit history intact (you can grep `RESOLVED` to see what shipped) and gives the cleanup orchestrator something to mark off.

Re-shoot screenshots after the fix at both viewports and save as `wN-{route}-{viewport}-fixed.png`. Side-by-side comparison is the verification artifact.

## Phase 6 — Triage + tickets

After Phase 4 finishes (matrix fully checked), write the audit report:

`docs/plans/{YYYY-MM-DD}_{app}_ui_audit.md` (in the repo, this one IS git-tracked):
1. **Coverage matrix** — copy the headline counts (`done=N/N`, `na=K`, `pending=0`).
2. **Findings rollup** — table of `(id, screen, severity, category, evidence-path)`.
3. **Systemic-pattern dedup** — when N findings have the same root cause, collapse them: "Spacing scale violated across N screens → one Design System ticket, not N."
4. **Out of scope** — explicitly list anything NOT exercised (e.g., Square payment WebView inner flow, OAuth provider redirects) with reasons. The user has corrected for missing this before; do not skip.

Then file tickets via the right skill:

| Tracker | Skill |
|---|---|
| Vikunja (BNB) | `vikunja-subtask-conform` (for restructuring), or direct via `vikunja` MCP for per-finding tickets |
| Jira (client) | `jira-subtask-conform`, or direct via Atlassian MCP |
| GitHub Issues | `gh-workflows` skill, label `ui-audit` |

One parent story "UI audit {YYYY-MM}" in the QA epic tracks the audit itself; per-finding tickets live in the appropriate feature epics (per `vikunja-subtask-conform` / `jira-subtask-conform` template rules).

## Phase 7 — Hand off

Output a one-paragraph status:

```
UI audit {project} {date} — N routes + M screens audited, K findings (P0:a, P1:b, P2:c, P3:d).
Coverage: matrix N/N done.
Artifacts: ~/.agent/evals/{project}/ui-audit-{date}/
Report: docs/plans/{date}_{app}_ui_audit.md (PR #aaa)
Tickets: parent story #X, N child tickets across {epic}, {epic}.
Next step: invoke `bug-bash` with findings.md as the Phase 2 inventory to dispatch cleanup, OR cherry-pick Batch A clusters directly.
```

## Verification

Before reporting the audit done:

- [ ] `grep -c '^- \[x\]' matrix.md` + `grep -c '^- \[N/A\]' matrix.md` == total row count
- [ ] Every finding has an evidence-path that resolves to a real file under `~/.agent/evals/{project}/ui-audit-{date}/`
- [ ] Report PR mentions every P0 + P1 finding by ID
- [ ] Out-of-scope section is explicit (no silent gaps)
- [ ] All tickets land in the correct epic per the project's template

## Anti-patterns

- **Do not** save screenshots inside the repo. Path is `~/.agent/evals/{project}/ui-audit-{date}/`. Repo `git clean` will erase them; `.gitignore` won't help if they're staged.
- **Do not** trust a hand-typed route list. Always derive from `find apps/.../page.tsx` (or framework equivalent). The user has caught missing routes before because of this.
- **Do not** fix bugs during the audit. Surface first, triage second, fix via `bug-bash`. Mixing them loses the inventory.
- **Do not** silently skip a route. `[N/A] /route — reason` is fine; an unchecked box is a coverage hole.
- **Do not** file one finding per route when the root cause is shared. One cluster = one finding = one fix PR.
- **Do not** ignore the dev-server watchdog — Next.js dies mid-audit often enough that "no watchdog" wastes a wave. The crash is environmental, not a finding.
- **Do not** auto-restart a dev server mid-audit without recording the crash as evidence. The audit must surface env fragility, not paper over it.
- **Do not** invoke `bug-bash-wrapup` before all Batch A fixes have merged — its job is regression specs, which need the merge commits.

## Helpers

### Matrix sync from findings.md

When the walkthrough writes findings.md but skips the matrix checkboxes (happens when an agent is interrupted), back-fill the matrix:

```python
# ~/.agent/evals/{project}/ui-audit-{date}/sync-matrix.py
import re, pathlib
D = pathlib.Path(__file__).parent
findings = D / 'findings.md'
matrix = D / 'matrix.md'

# Parse "### WN-NN | route | ... | category | P{n}" lines
finding_routes = {}  # finding-id -> list of routes
for line in findings.read_text().splitlines():
    m = re.match(r'### (W\d+-\d+) \| ([^|]+) \|', line)
    if m:
        fid, routes = m.group(1), [r.strip() for r in m.group(2).split(',')]
        finding_routes[fid] = routes

# For each matrix row "- [ ] /route", check the box if any finding mentions it
text = matrix.read_text()
done = pending = 0
for fid, routes in finding_routes.items():
    for route in routes:
        text = text.replace(f'- [ ] {route}', f'- [x] {route} | both viewports | (see findings) | {fid}')
matrix.write_text(text)
done = text.count('- [x]')
pending = text.count('- [ ]')
print(f'matrix synced: done={done} pending={pending}')
```

## Related

- `bug-bash` — consumes this skill's `findings.md` as its Phase 2 inventory; runs the fix dispatch
- `bug-bash-wrapup` — writes regression e2e specs from the resolved findings; runs after Batch A merges
- `sc:manual-test` — single-PR verification; ui-audit composes the same Playwright/adb patterns at scale
- `adb-ops` — mobile emulator/logcat/screencap
- `bnb-quality-gates` — e2e hygiene rules (no `waitForTimeout`, etc.) that any spec written from findings must follow
- `vikunja-subtask-conform`, `jira-subtask-conform` — ticket structuring after findings are triaged
- `prod-smoke-suite` — the other half of "find broken things on a real system"; ui-audit is design/UX-shaped, prod-smoke-suite is contract/integration-shaped
- `~/.agent/evals/{project}/` — canonical artifacts root

## Reference targets

- `bnb-platform` — primary reference. The 2026-06-04 PMP audit at `~/.agent/evals/bnb-platform/ui-audit-2026-06-04/` is the canonical example: 43 web routes + 30 mobile screens, 6 waves, ~75 screenshots, ~51 findings across P0–P3, ticketed in Vikunja (audit story #192).
