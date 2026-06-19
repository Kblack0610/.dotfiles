---
name: delta-audit
description: Scoped "audit + fix + ship" loop for the surfaces that CHANGED since the last release/audit — not a whole-app sweep. Derives the delta from git + the prior ui-audit findings, verifies each changed screen LIVE (Playwright web @390/1280, Expo-web/adb mobile light/dark) with DOM-measured confirmation (never trust a screenshot's eyeball read), fixes confirmed P0–P2 issues using the repo's documented spacing/layout conventions, and ships PR→CI→merge with a Vikunja ticket. Use when the user says "do another audit and pass", "audit what we just shipped", "delta audit", "clean up the new feature before release", or after a feature/batch lands and you want the new UI verified + polished. Differs from ui-audit (whole-app, coverage-guaranteed, hands fixes to bug-bash — this skill is delta-scoped AND fixes+merges itself) and sc:manual-test (single-PR walkthrough). Pairs with ui-audit (consumes its findings.md as the "already-fixed" baseline) and the kb-developer/worktree pattern for parallel fixes.
---

# delta-audit

A tight, iterable **audit → verify-live → fix → ship** loop scoped to *what changed*. Born from running the same pass 3× in one session (image batch, UI padding, notifications). The whole point: don't re-audit what's already fixed — audit the *delta*, prove issues with measurements (not vibes), fix with the codebase's own conventions, and merge it green.

## When to invoke

- "do another audit and pass" / "audit what we just shipped" / "delta audit before the release"
- After a feature/batch merges and you want its NEW UI verified + polished
- A focused re-check of a few changed screens (not a whole-app sweep → that's `ui-audit`)

Do **not** use for: a brand-new whole-app audit (`ui-audit`), a single PR you're actively building (`sc:manual-test`), or backend correctness (`bug-bash`).

## Core principles (the hard-won ones)

1. **Audit the delta, not the world.** The prior `ui-audit` findings.md + git history tell you what's already fixed. Re-fixing resolved findings is busywork. Scope to surfaces changed since the last audit/release.
2. **Verify-don't-trust.** A scaled screenshot LIES about overlap/spacing. Confirm every suspected finding with a DOM measurement (`getBoundingClientRect`, `getComputedStyle`, `scrollWidth > innerWidth`) before calling it real. (This session: a "buttons overlapping" finding was a pure screenshot-scaling artifact — DOM showed them on separate rows.)
3. **Seed real data.** Pages render truthfully only with real content. For image/list screens, inject real public asset URLs (e.g. pull `*.digitaloceanspaces.com` URLs from the prod API) into a dev row, audit, then **revert**. next/image only loads allow-listed hosts — fake hosts show the fallback and hide the real layout.
4. **Fix with the repo's conventions, not freelance CSS.** Map the existing patterns first (PageContainer variants, `flex flex-col gap-3 sm:flex-row` stacking, `hidden md:flex`/`md:hidden`, mobile spacing tokens + safe-area). Match them.
5. **Touch ≠ touchable.** `opacity-0 group-hover:opacity-100` controls are invisible on touch. For edit affordances use `opacity-100 md:opacity-0 md:group-hover:opacity-100`.
6. **Never trust a textual merge.** When parallel PRs touch the same file, `git merge-tree`/"0 conflicts" can still be SEMANTICALLY broken. Before merging: `git checkout -B tmp origin/develop && git merge <branch>`, grep for the moved code, run typecheck + component tests on the merged tree. Prefer sequential PRs for shared files; parallel only for non-overlapping files.
7. **A settings/preferences UI is a CLAIM about behavior — verify it against the BACKEND's actual delivery gates, not just the UI's internal consistency.** They drift silently. Read the server resolver + any per-channel allowlist, render the screen for a zero-saved-state account (pure defaults), DOM-measure each cell, and reconcile cell-by-cell. (2026-06-18: the notification matrix showed push OFF / email available for events the backend actually pushed / never emailed.)

## Inputs

- **Target app** + repo path (e.g. `/home/kblack0610/dev/bnb/platform-agent-2`, `apps/placemyparents/{web,mobile}`).
- **Delta source** — the feature/PRs/date to scope to (e.g. "the notification UI", "everything since v1.8.11", PR #s).
- **Project key** — for artifact path under `~/.agent/evals/{project}/`.

## The loop

### 0. Working tree
Ensure a usable checkout on a fresh branch off `origin/develop` (recreate a worktree if the prior one was recycled). `pnpm install`; build shared packages (`pnpm build --filter="./packages/**"`) — apps won't boot without them. Decrypt env (`./scripts/env-decrypt.sh` with `SOPS_AGE_KEY_FILE=~/.config/sops/age/keys.txt`) so the API has `DATABASE_URL`/`JWT_SECRET`. `docker exec -i <pg>` needs `-i` for heredocs.

### 1. Scope the delta
- Read the prior `~/.agent/evals/{project}/ui-audit-*/findings.md` + `matrix.md` → the "already-fixed baseline".
- `git log --oneline <last-tag>..HEAD` for the app dirs → the changed surfaces.
- List the concrete screens/routes to re-check (and a short spot-check list of prior P0 fixes to confirm they still hold).

### 2. Verify live (this is the skill's spine)
- **Web:** `pnpm dev` api+web; seed real data; Playwright MCP at **390** and **1280**. For each screen: screenshot (Read the .jpeg to actually look), then DOM-measure any suspicion. Test interactions (open/close, keyboard, toggles) + assert `getComputedStyle`/rects. 0 console errors is part of the bar.
- **Mobile:** Expo web (`pnpm --filter <mobile> web`, login via real Playwright click — RN-web Pressable needs a real event sequence, synthetic dispatch often won't fire) for a quick light/dark pass; `adb-ops` emulator for native-only bits (camera/push). Static-check theme tokens for dark-mode safety when an emulator isn't available, and SAY SO.
- Log to `~/.agent/evals/{project}/delta-audit-{date}/findings.md`, severity-coded (P0–P3), with the DOM evidence that confirms each.

### 3. Fix (P0–P2; defer P3 unless asked)
- Small, area-batched edits using the conventions from principle 4. Re-verify each fix live at the same viewport/theme (the rect/opacity is gone/correct).
- Run the touched packages' `typecheck` + component tests.

### 4. Ship
- Vikunja ticket (epic 17 / the relevant epic), `In Development` + `P*` + area labels; PR body carries `Vikunja: <id>`.
- PR → poll CI (Type Check, Build, Code Quality, Web/Mobile Smoke ~15min) → merge to `develop` only when CLEAN. For parallel fix branches sharing files, apply principle 6.
- Revert seeded dev data; stop dev servers. Append a **Results** section to the plan file; close the ticket (the close-on-merge hook may be offline — verify, close manually if so).

## Parallelizing fixes (when the delta is large)
Dispatch `kb-developer` agents with `isolation: worktree`, `run_in_background: true`. **Non-overlapping files → parallel; shared files (channel registry, a shared component) → sequential, merging each before the next.** Always run the local merge-check (principle 6) before merging any agent's PR.

## Artifacts
```
~/.agent/evals/{project}/delta-audit-{YYYY-MM-DD}/
├── findings.md                 # severity-coded, with DOM evidence per finding
├── {screen}-{viewport}.jpeg            # before
└── {screen}-{viewport}-fixed.jpeg      # after
```
Never write artifacts inside the target repo.

## Iterating on this skill
After each run, fold new lessons in here (and into `~/.agent/lessons/{project}.md`). This file is meant to be edited every pass — that's the point.
