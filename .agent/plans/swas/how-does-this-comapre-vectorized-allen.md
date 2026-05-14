# bsn-dashboard vs. GP Platform (Amazon Media Player Fleet) — Comparison

## Context

You asked how this repo (`/Users/kenneth.black/dev/bsn-dashboard`) compares to the
Amazon fleet platform you're scoping in
`~/.notes/employment/jobs/gigantic_playground/media_player_fleet/` for Gigantic
Playground (Drive folder `1XyrCZgQySLZ0hZCX2AXSA7lh1FTQf-m1`). Short answer: this
repo **is the Phase 1 dashboard prototype** of the GP Platform. The tech spec
explicitly labels it "~80–90% complete" and treats it as the seam through which
the production system will be built — not a different system.

This document maps that relationship: shared DNA, what already exists, what's
missing for the production GP Platform, and which scope items are net-new.

---

## 1. Shared DNA (already aligned)

| Concern | bsn-dashboard today | GP Platform spec |
|---|---|---|
| Auth to BSN.cloud | OAuth2 `client_credentials`, in-memory token cache w/ 30s expiry buffer (`server.js:40`) | Identical pattern — moves to RDS-backed session store |
| API surface | `api.bsn.cloud/2022/06/REST` Devices/Self/Session/Network calls (`server.js:95 bsnRequest`) | Same surface — wrapped behind `IFleetManagementAdapter` |
| B-Deploy provisioning | `provision.bsn.cloud/rest-device/v2` via `bdeployRequest` (`server.js:131`) | Same — drives enrollment records |
| Remote screenshots | `ws.bsn.cloud/rest/v1/snapshot` Remote DWS POST (`server.js:370`) | Same — used for content verification + alerting |
| Remote logs | DWS `/rest/v1/logs` (`server.js:438`) | Same — feeds alert engine + diagnostics |
| Health polling | `pollHealth()` interval w/ Slack alerts (`server.js:542`) | Generalized into "SLA Alert Engine" w/ rule tiers |
| Frontend | Vanilla JS SPA, dark theme, fleet overview + per-player cards | Same shell — extended with sensor/SLA/dispatch panels |
| Node/Express proxy | Required because BSN.cloud has no CORS | Same architectural constraint |

**Takeaway:** every BSN.cloud call shape, the OAuth flow, the DWS relay pattern,
and the dashboard rendering model are already correct. The production work is
hardening + scope expansion, not redesign.

---

## 2. Gap analysis — what bsn-dashboard lacks for production GP Platform

Grouped by tech spec section.

### 2.1 Persistence (spec §1.2)
- **Today:** in-memory session, in-memory device cache, in-memory alert log
  (`server.js:519 logAlert`), no history beyond process lifetime.
- **Needed:** RDS PostgreSQL for device inventory, alert history, SLA records,
  sensor gap log. Resets on server restart are unacceptable for SLA-bound work.

### 2.2 Adapter abstraction (spec §2.2)
- **Today:** `bsnRequest()` and `bdeployRequest()` are called directly from route
  handlers — the BSN.cloud URL is baked in.
- **Needed:** `IFleetManagementAdapter` interface w/ `BsnCloudAdapter` and
  `AmazonApiAdapter` implementations. Spec calls this 2–3 days of refactor and
  the minimum defensive posture against Amazon's "custom API layer" of unknown
  scope (Blocker B2).

### 2.3 SLA Alert Engine (spec §1.2 row 7)
- **Today:** single Slack post when health flips (`server.js:524`).
- **Needed:** tiered SLA rules (Flagship 15-min vs. Standard tiers), escalation
  graph, ticket dispatch to 130 Amazon market managers. Whether the 15-min
  Flagship tier is achievable via polling depends on BSN.cloud rate limits
  (Blocker B6).

### 2.4 Sensor pipeline (spec §1.2, §2.1)
- **Today:** none — dashboard is BrightSign-only.
- **Needed:** ingestion of Darko / Outform / Lynx telemetry into Amazon-owned
  S3 (`s3://amz-media-player-fleet/sensors/...`), per-station health rollups,
  gap detection, SWAS MQTT broker integration.

### 2.5 Multi-device support (spec §1.2 last row)
- **Today:** BrightSign players only (XT1144 + similar).
- **Needed:** Echo Show, Fire TV/Tablet, Lynx, LG&P endpoints under a unified
  device model. Phase 1 is BS-only; Phase 2 expands.

### 2.6 CMS layer (spec §2.4)
- **Today:** none — no content scheduling, no `autorun.zip` publishing.
- **Needed:** depends on Option A (bsn.Content integration) vs. Option B
  (GP-built Partner App writing to Amazon S3). Open decision.

### 2.7 Field-scoped views (spec §1.2 dashboard row)
- **Today:** single global view, no auth, no role separation.
- **Needed:** Operations dashboard (Amazon Ops Manager), Field dashboard (130
  market managers, scoped to their stores), GP-internal view.

### 2.8 Security posture
- **Today:** credentials entered through browser form, in-memory only,
  passwords redacted before forwarding (per CLAUDE.md). Fine for prototype.
- **Needed:** RDS-stored secrets via AWS Secrets Manager / IAM, audit logging,
  ISO 27001 controls per Amazon InfoSec. Plus the SWAS lessons (no hardcoded
  MQTT password, real admin auth) carried over to the new build.

---

## 3. Things in this repo that are *not* in the spec (and may need a home)

- `proximity` and `proximity-logger` directories — outside the scope of
  bsn-dashboard's documented purpose. Worth deciding if they belong in this
  repo, in `swas`, or get archived.
- API Explorer panel — useful for development; the spec doesn't mention it.
  Probably stays as an internal-only tool.

---

## 4. Recommendation (no action requested yet)

This repo is on the right architectural arc. The two cheapest moves that meaningfully
de-risk the GP Platform contract — and could be done independently of any Amazon
decision — are:

1. **Adapter refactor (spec §2.2 Option A).** Wrap `bsnRequest` /
   `bdeployRequest` behind `IFleetManagementAdapter`. ~2–3 days. Hard requirement
   if Amazon's custom API layer materializes; defensive otherwise.
2. **Persistent store.** Move session, device cache, and alert log out of
   process memory into Postgres. Without this, no SLA claim is defensible.

CMS, sensors, multi-device, and field-scoped views are larger scopes that
depend on decisions still open in `open_questions.md` and the SOW negotiation.

---

## 5. Critical files referenced

- `/Users/kenneth.black/dev/bsn-dashboard/server.js` — current implementation
- `/Users/kenneth.black/dev/bsn-dashboard/public/index.html` — current SPA
- `~/.notes/employment/jobs/gigantic_playground/media_player_fleet/tech_spec.md` —
  GP Platform architecture (the comparison target)
- `~/.notes/employment/jobs/gigantic_playground/media_player_fleet/prd.md` — scope
- `~/.notes/employment/jobs/gigantic_playground/media_player_fleet/cms_options.md` —
  CMS A/B/third-party analysis
- `~/.notes/employment/jobs/gigantic_playground/media_player_fleet/open_questions.md` —
  blockers + SOW-negotiation items
- `~/.notes/employment/jobs/gigantic_playground/fleet-manager.md` — broader
  fleet-manager planning notes

---

## 6. Action — fold this into `tech_spec.md`

The brief above is the analysis; the action is to land it next to the spec it
references, so it survives plan-archive and informs the R1 deck (due 2026-05-19).

**File to edit:**
`~/.notes/employment/jobs/gigantic_playground/media_player_fleet/tech_spec.md`

**Insertion point:** new top-level section between §1 "System Context" and §2
"Dependency Analysis", titled `## 1.3 Prototype Delta — bsn-dashboard vs.
GP Platform`. Rationale: §1 establishes the target architecture; §1.3 anchors
where today's prototype sits against it; §2 then lists the blockers — the flow
reads cleanly.

**Section content (concise, deck-ready):**

1. **One-paragraph framing:** the bsn-dashboard repo is the Phase 1 dashboard
   prototype; the production GP Platform extends it rather than replaces it.
   Cites `server.js` line ranges so the spec stays grounded in real code.
2. **"Aligned" table:** columns = Concern / bsn-dashboard today / GP Platform
   spec. Rows = the 8 from §1 of this brief (auth, API surface, B-Deploy,
   screenshots, logs, polling, frontend, proxy).
3. **"Gap" table:** columns = Spec section / What's missing / Effort sketch.
   Rows = the 8 from §2 of this brief (persistence, adapter, SLA engine,
   sensors, multi-device, CMS, field views, security).
4. **"Out-of-scope today" callout:** `proximity` and `proximity-logger`
   directories — flag a decision to relocate or archive.
5. **R1 deck hook:** explicit note that this section is the source for the
   R1 "current state vs. target state" slide.

**What this does NOT do:**
- No code changes to bsn-dashboard.
- No edits to PRD, CMS options, or open questions.
- No ClickUp ticket changes.
- Does not pre-empt the adapter refactor or RDS migration plans — those
  remain on the spec's roadmap and get sequenced in the existing ticket
  breakdown work.

**Verification:**
- Read `tech_spec.md` after edit and confirm §1.3 sits between §1.2 and §2.0
  with no broken anchors.
- Confirm tables render in Obsidian preview.
- Sanity-check that every row in the "Aligned" table cites an existing
  `server.js` line range or function name.

**Critical files to read before editing:**
- `~/.notes/employment/jobs/gigantic_playground/media_player_fleet/tech_spec.md`
  (full file — verify section numbering and existing prototype references)
- `/Users/kenneth.black/dev/bsn-dashboard/server.js` (line numbers for the
  Aligned table cites)
- `/Users/kenneth.black/dev/bsn-dashboard/CLAUDE.md` (cross-check the
  "Out-of-scope" callout — the proximity dirs are not mentioned there either)
