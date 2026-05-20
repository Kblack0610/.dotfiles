# Plan — Amazon Media Player Fleet: Per-Ticket Implementation Steps

> **Updated after repo exploration (2026-05-13).** All implementation steps are grounded in what actually exists in the three local repos. Steps that say "add" or "extend" mean the scaffold is already there; steps that say "build" mean net-new work.

---

## Repo State Summary (read before implementing anything)

| Repo | Path | State | Key Finding |
|------|------|-------|-------------|
| `brightsign-app-deployment-setup-test` | `~/dev/brightsign-app-deployment-setup-test` | **Verified working** (commit `bb1e6ac`, 2026-04-28) | Full Partner App virgin onboarding flow WORKS: SD card → BSN.cloud enrollment → S3 `autorun.zip` pull → 30-min OTA loop. Tested on 1 device. S3 bucket: `brightsign-app-hosting-test` (GP-owned, AWS `590183653052`, `us-west-2`). BSN.cloud account: `AustinTestBSNCloud` (Austin's trial). |
| `swas` | `~/dev/swas` | Production (NFM live) | **Zero BSN.cloud integration.** BrightSign content delivered via file:// from manual USB/SCP. No S3. LS5 sensor scripts deployed manually. CRITICAL security issues still present (hardcoded MQTT password `lighting_script.js:34`, no admin UI auth). |
| `bsn-dashboard` | `~/dev/bsn-dashboard` | Early prototype (2 commits) | **~80-90% of Operations dashboard already built** — OAuth, device list, health badges, screenshots, Slack alerts, log viewer all working. Missing: persistent DB, SLA metrics, escalation rules, sensor-specific views, multi-network support. |

### Blockers That Must Be Resolved Before Implementation

| Blocker | Blocks | Owner | Status |
|---------|--------|-------|--------|
| Austin's BSN.cloud trial expiring (`austin.humes@giganticplayground.com`) | All prototype / dashboard work | Austin / Jay | Ask for extension or Amazon account access |
| Amazon AWS account + S3 bucket provisioning | Deployment system (`86e1bpgme`), moving off GP-owned `brightsign-app-hosting-test` | Amazon | Not started |
| Amazon BSN.cloud network (not Austin's trial) | Fleet enrollment, dashboard real data | Amazon / BrightSign | Not started |
| BBY Canada SWAS store list confirmation | SWAS BBY Canada scope, contract pricing | Amazon | Approximate only |
| CMS Option A vs. B decision | Content delivery architecture | Matt / Amazon | Open |
| BrightSign contact for API questions (rate limits, BDeploy vs. Partner App) | `86e1bpgme` architecture | Austin / BrightSign | Austin has contact |

---

## Context

GP is in late-stage negotiation with Amazon on a managed-services contract for their retail media-player fleet (Echo Show, BrightSign, Fire TV, smart sensors across BBY US, BBY Canada, Lowe's, Brandsmart, Nebraska Furniture Mart, etc. — ~17,700+ endpoints once full-fleet rollout starts). The 2026 Phase 1 scope (~$1.4M to GP, plus BrightSign licensing + AWS pass-through) is:

1. **GP Platform + Dashboard buildout** (one-time, ~$980K with 3-year discount)
2. **Play Table at Best Buy US** — ~650 stores, 6,500 monitored endpoints
3. **SWAS at Best Buy Canada** — 6 stores, ~306 endpoints (extension of the proven NFM SWAS pattern)
4. **BSN.cloud Control Cloud integration** (free tier — device management API foundation)
5. **CMS layer** — open question: pay BrightSign for bsn.Content (Option A) vs. GP builds CMS into Platform via BrightSign "Partner App" mode (Option B), or third-party CMS partners (Signagelive, Appspace, Navori, etc.)
6. **Sensor monitoring** — first-time fleet-wide health for Darko, Outform, Lynx sensors
7. **Three dashboards** — Executive, Operations, Field
8. **AI-powered content verification** (Amazon Bedrock)
9. **SLA tiers + automated dispatch** to 130 Amazon market managers
10. **Existing S3 sensor pipeline** instrumented (not replaced)

**Kenneth's six assigned ClickUp tickets** (List: Fleet Management System, ID `901713708011`; SOW parent: `86e1bpjze`):

| ID | Title | Due | Notes |
|----|-------|-----|-------|
| `86e1bpk74` | High level deliverables breakdown | 2026-05-22 | "Reference Matt's deck — consolidate into client-facing language." PDF attached. |
| `86e1bp68j` | **R1** Architectural overview slide deck (BS + AMZ) | 2026-05-19 | "Attendants may not be tech folks — strike a balance." |
| `86e1bpc5j` | └ Document and validate existing BS deployment process | — | subtask of R1 |
| `86e1bpbka` | └ Document and validate "virgin" BS deployment + **workable prototype** | — | subtask of R1 |
| `86e1bp89c` | **R2** Architectural overview slide deck (BS + AMZ) | 2026-05-25 | co-assigned to Austin Humes; iterates on R1 |
| `86e1bpgme` | Initial deployment system for new BS players | ~2026-06-04 | "Think about architecture, design, document." |

(Pacman POC `86e1burn3` is explicitly excluded per user.)

**What the user is asking for:** there is no PRD yet — the source-of-truth artifacts are the proposal PDF/HTML, Matt's Andy follow-up (April 2026), the sensor-pricing/CMS response, BrightSign questions doc, and the fleet calculator spreadsheet. The user wants the kb-* pipeline to (a) draft a PRD that consolidates this into a clear product definition, then (b) hand it to kb-architect to produce a tech spec and a clean, well-defined ticket breakdown.

**Intended outcome:** by the end of this work, Kenneth has a single coherent PRD + tech spec + ticket plan that lets him drive R1/R2 decks, the deployment writeups, the prototype, and the SOW deliverables breakdown without re-deriving scope from the proposal each time.

## Approach

Two-stage agent pipeline, with a CMS-analysis sidecar that the PRD references:

```
  Phase 0: Workspace setup (mkdir + index)
       │
       ▼
  Phase 1: kb-product-owner  →  prd.md
       │              + cms_options.md (sidecar, full options analysis)
       │              + open_questions.md
       ▼
  Phase 2: Review + user checkpoint (does the PRD reflect intent?)
       │
       ▼
  Phase 3: kb-architect  →  tech_spec.md
       │              + ticket_breakdown.md  (maps to ClickUp IDs)
       │              + deployment/existing_process.md
       │              + deployment/virgin_process.md
       │              + prototype_plan.md  (extends ~/dev/brightsign-app-deployment-setup-test)
       │              + decks/r1_outline.md
       │              + decks/r2_outline.md
       ▼
  Phase 4: User reviews; iterates on tickets/decks before any ClickUp edits.
```

The architect does **not** modify ClickUp directly — it proposes the ticket breakdown in a markdown table, and Kenneth applies updates after review (ClickUp edits are out-of-scope for this planning task).

## Output Layout

All outputs in `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/media_player_fleet/`:

```
media_player_fleet/
├── README.md                       # index + how-to-read
├── prd.md                          # Phase 1 — Product Brief / PRD
├── cms_options.md                  # CMS landscape: Option A, B, third-party CMSs
├── open_questions.md               # blockers / decisions needed from Matt / Amazon
├── tech_spec.md                    # Phase 3 — Architecture, components, data flows
├── ticket_breakdown.md             # Refined tickets, mapped to ClickUp IDs
├── prototype_plan.md               # Roadmap for ~/dev/brightsign-app-deployment-setup-test
├── deployment/
│   ├── existing_process.md         # ticket 86e1bpc5j deliverable
│   └── virgin_process.md           # ticket 86e1bpbka deliverable
└── decks/
    ├── r1_outline.md               # ticket 86e1bp68j deliverable
    └── r2_outline.md               # ticket 86e1bp89c deliverable
```

## Source-of-Truth Inputs (agents must read these)

**Local notes (already on disk):**
- `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/overview.md`
- `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/tech_orientation.md` — SWAS + OnDeviceScreenDemo orientation
- `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/tech_analysis_swas.md` — SWAS deep-dive findings (CRITICAL/HIGH issues incl. hardcoded MQTT password)

**Google Drive — Tech Docs folder (PRIMARY, folder ID `1zhv8krTZ2GI-Z0_juA__4xFVbyhsjSb2`):**
This folder is the designated source of truth for all technical documentation on this project. Agents must check here first and treat its contents as authoritative. When a doc exists in both this folder and the Media Player RFP folder, prefer this one.

**Google Drive — Media Player RFP folder (`1XyrCZgQySLZ0hZCX2AXSA7lh1FTQf-m1`) (secondary — proposal + commercial docs):**
- `amazon-media-player-proposal.md` (fileId `1qD5xZTa6g1wi73-4cpDQm1ZYAxak7HOj`, 57KB) — the canonical proposal
- `response-to-andy-followup-questions-april.md` (fileId `1CwXfztLWLydAGlyJboRSTot6riVCa2UC`) — InfoSec, support model, parameter flexibility, 2026 payment schedule
- `response-to-andy-sensor-pricing-and-cms.txt` (fileId `1QIWxTSTxi0QlCCvX62jDcxfpKvDGH5lu`) — per-sensor pricing, CMS Option A/B walkthrough
- `Questions For Brightsign` (Google Doc, fileId `1fSRn8Zrtdt1Apvv6viOpaJX4Hh2GeyIRkokM6lgavn8`) — BS player model inventory, publishing modes, fleet onboarding open questions
- `AMZ GP Fleet Calculator` (Sheet, fileId `1nXYjGtBtpPK9iXOprVkdrJ7O7DBn14XkTwPraNwpdJA`) — 2026/2027/2028 cost model
- `AMZ Media Player Fleet Project Model` (Sheet, fileId `14rxATYIPTnKJu-c2YwPraNwpdJA`) — project planning model

**ClickUp:**
- Workspace `9006092294`, Space `90170789902` (Client: Amazon), List `901713708011` (Fleet Management System), SOW parent `86e1bpjze`

**Local repos (already cloned):**
- `/Users/kenneth.black/dev/swas` — proven SWAS pattern (extending to BBY Canada)
- `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test` — existing deployment prototype to extend
- `/Users/kenneth.black/dev/bsn-dashboard` — dashboard work-in-progress

## Phase 0 — Workspace setup (Claude does this directly)

1. `mkdir -p` the directory tree above.
2. Write `README.md` index linking each output.
3. Drop a brief "sources" subsection in the README pointing at the inputs above.

## Phase 1 — kb-product-owner (writes PRD)

Invoke `kb-product-owner` agent (foreground). Prompt brief:
- **Goal:** consolidate the proposal + Andy follow-ups + sensor/CMS response + fleet calculator into a single Product Brief covering the **full 2026 Phase 1 scope**, with Kenneth's six assigned ClickUp tickets as the first execution slice.
- **Required sections:**
  1. Problem statement (Amazon's current pain — 17,700+ players, no centralized management, blind to sensor health)
  2. Goals + non-goals for Phase 1
  3. Users + personas (Amazon Executive, Amazon Operations, Amazon Field/Market Managers, GP internal, BrightSign as sub-vendor)
  4. Scope: Play Table BBY US (6,500 endpoints), SWAS BBY Canada (306 endpoints), Platform + Dashboard build, sensor monitoring, CMS layer
  5. Out of scope for Phase 1 (Lowe's, Brandsmart, full NFM SWAS rollout, ML modeling — deferred to Phase 2/3 per proposal)
  6. Success metrics (SLA detection times by tier, sensor uptime visibility, ticket-to-fix lead time, content-verification accuracy)
  7. Key constraints (Amazon InfoSec / data governance, Amazon-owned S3 buckets, BSN.cloud licensing economics, 130-market-manager field model)
  8. Open questions + decision log (cross-reference `open_questions.md`)
  9. Mapping table: which ticket maps to which PRD section

- **Output files:**
  - `prd.md`
  - `cms_options.md` — separate sidecar
  - `open_questions.md`

- **CMS sidecar (`cms_options.md`) requirements:**
  - Comparison matrix across at minimum: (a) bsn.Content paid CMS, (b) GP builds CMS via BrightSign "Partner App" mode, (c) BrightSign-compatible third-party CMSs (Signagelive, Appspace, Navori, Yodeck, ScreenCloud), (d) self-built without BrightSign Partner App
  - For each: cost model, vendor-lock risk, multi-device support (BS only vs. BS+Echo+Tablet+Lynx+LG&P), feature gaps, integration with the GP Platform, time-to-deploy
  - Recommendation section: per the Andy sensor/CMS response, GP is leaning Option B (Partner App with GP CMS). Validate or challenge that lean. Recommend Option B *only* if the evidence supports it after looking at all options.

- **Required reads before drafting:** all six Drive files listed above + the three local notes files + the SOW parent ticket. Pull verbatim quotes/tables from the proposal where useful (pricing tables, fleet inventory, SLA tiers).

## Phase 2 — User checkpoint (no agent)

Claude pauses after Phase 1 completes and surfaces the PRD + CMS options to the user for review. User confirms (or requests revisions to) the PRD before kb-architect runs. This is important because the tech spec is downstream of PRD decisions, especially the CMS recommendation.

## Phase 3 — kb-architect (writes tech spec + tickets)

Invoke `kb-architect` agent (foreground). Prompt brief:
- **Goal:** produce a tech spec for the 2026 Phase 1 build that an engineering team could execute against, plus a refined ticket breakdown mapped to Kenneth's ClickUp work.
- **Required reads:** `prd.md`, `cms_options.md`, all source-of-truth inputs listed above, plus exploration of `/Users/kenneth.black/dev/swas`, `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test`, `/Users/kenneth.black/dev/bsn-dashboard` for re-use opportunities (do NOT design new code where existing code already covers it — extend instead).
- **Required `tech_spec.md` sections:**
  1. System context diagram (in mermaid) — GP Platform, Amazon AWS, BSN.cloud Control, sensors, fixtures, S3 pipeline, dashboards, field workflows
  2. Component breakdown (per-service responsibility, tech stack, hosting, scaling assumptions)
  3. Data model + flows — sensor events → S3, device telemetry → GP Platform, alerting → ticketing → dispatch
  4. BSN.cloud integration: bsn.Control API surface used (Devices, Screenshots, Reboot, Firmware), rate limits, auth model, fleet-status polling vs. webhook strategy. Reference the `Questions For Brightsign` doc for open API questions to resolve.
  5. CMS layer design (driven by the Option B recommendation, with a "what changes if Option A" callout)
  6. Deployment subsystem (covers tickets `86e1bpc5j`, `86e1bpbka`, `86e1bpgme`):
     - Existing BS deployment process (audit + diagram of current state)
     - "Virgin" onboarding flow (factory-fresh BS player → in fleet)
     - New `Initial Deployment System` design — BDeploy records, autorun.zip publishing, SD-card provisioning, S3 content endpoint, check-in cadence, fallback behavior
  7. Multi-device strategy — how the same platform supports BS, Echo, Tablet, Lynx, LG&P (per CMS sidecar's Option B argument)
  8. Sensor monitoring architecture — per-sensor health, calibration drift detection, alert routing
  9. SLA implementation — alert→ticket→dispatch latency targets per tier, escalation graphs
  10. AI / Bedrock integration — content-verification model, dashboard intelligence
  11. Security + compliance — ISO 27001 controls, Amazon InfoSec re-engagement plan, where MQTT password lessons from SWAS apply (the SWAS tech-analysis flagged a CRITICAL hardcoded password — this must NOT recur in the new build)
  12. Phasing within Phase 1 — what ships first (deployment prototype + dashboard MVP) vs. last (AI content verification)
  13. Risks, unknowns, dependencies (Amazon AWS account, store-list confirmation, BS API access, InfoSec contact)

- **`ticket_breakdown.md` requirements:**
  - One row per ticket. Columns: ClickUp ID (or "NEW"), title, refined description, acceptance criteria, dependencies, est. effort (rough T-shirt size), suggested assignee.
  - Refine the six existing tickets first; then propose new tickets to cover platform/dashboard/CMS/sensor work that the architect identifies as missing.
  - For each refined ticket, include the "as-is" description from ClickUp and the proposed replacement for clarity.
  - Do **not** invoke any ClickUp write tools. Output is a plan; Kenneth applies edits later.

- **`prototype_plan.md` requirements:**
  - Inspect `~/dev/brightsign-app-deployment-setup-test`. Summarize what's already there.
  - Define what "workable prototype" means for ticket `86e1bpbka` — entrance/exit criteria, which BS models to test on, what subset of the Initial Deployment System design it validates.
  - List concrete tasks to extend the existing repo to meet that bar.

- **`deployment/existing_process.md`** — covers ticket `86e1bpc5j`. Should be presentation-ready prose + diagrams for the R1 deck.

- **`deployment/virgin_process.md`** — covers ticket `86e1bpbka`. Same bar.

- **`decks/r1_outline.md`** and **`decks/r2_outline.md`**:
  - Slide-by-slide outline (title + 3-5 bullets per slide), tuned for a non-technical audience as the ticket spec requires.
  - R1: foundation deck — current state, problem, GP approach, existing + virgin deployment processes. Aimed at the May 19 BS+AMZ meeting.
  - R2: iteration — incorporates R1 feedback (placeholder), goes deeper on full architecture, sensor monitoring, dashboards. Aimed at the May 25 meeting.

## Phase 4 — User review (no agent)

Claude surfaces all outputs in a summary, points the user at the key decisions encoded in each doc, and identifies anything that still needs Matt/Austin/Amazon input before the May 19 R1 meeting.

## Critical Files to Reference (not modify)

- `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/overview.md`
- `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/tech_orientation.md`
- `/Users/kenneth.black/.notes/employment/jobs/gigantic_playground/tech_analysis_swas.md`
- Drive folder `1XyrCZgQySLZ0hZCX2AXSA7lh1FTQf-m1` (Media Player RFP) — all six docs listed above
- `/Users/kenneth.black/dev/swas` (read-only inspection for re-use)
- `/Users/kenneth.black/dev/brightsign-app-deployment-setup-test` (extend in Phase 3)
- `/Users/kenneth.black/dev/bsn-dashboard` (read-only inspection for re-use)

## Existing assets to reuse (do not re-invent)

- **SWAS MQTT pattern, time-sync, Mosquitto broker config** — extending to BBY Canada is *the same SWAS pattern as NFM*. Don't redesign; replicate, with fixes for the SWAS CRITICAL/HIGH issues flagged in `tech_analysis_swas.md` (hardcoded MQTT password, admin UI auth gap, lighting race condition).
- **bsn-dashboard repo** — already in flight; the Phase 1 dashboard build extends this rather than starts fresh.
- **brightsign-app-deployment-setup-test repo** — the prototype scaffolding for the virgin BS deployment flow.
- **GP Platform pattern from EFD / Tablet Demos** — already inside Amazon's perimeter for 18 months across 13,000+ devices. Per the Andy follow-up, the same monitoring/ticketing/dispatch pattern carries forward.

## Verification (how we'll know the plan executed correctly)

1. **PRD completeness:** all nine PRD sections present; the six ClickUp tickets each map to a PRD section; the proposal's pricing tables and fleet inventory are captured verbatim.
2. **CMS options:** at minimum five options evaluated; recommendation has explicit "why not Option A / not third-party" reasoning, not just "Option B wins."
3. **Tech spec consistency:** every PRD goal is addressed in at least one tech-spec section; the spec references the existing SWAS / dashboard / deployment repos by path; the SWAS security issues are explicitly addressed.
4. **Ticket breakdown:** each of the six assigned ClickUp tickets has a refined version with explicit acceptance criteria; new tickets cover any platform/dashboard/CMS/sensor work the architect identifies.
5. **Decks:** R1 outline can be opened in front of a non-technical audience and used as-is by Kenneth on May 19; R2 builds on R1.
6. **Prototype plan:** specific concrete tasks listed against `brightsign-app-deployment-setup-test`, not generic guidance.
7. **No accidental ClickUp writes:** all ticket changes are proposals in markdown, never executed against the ClickUp API.

## Open Risks / Things to Flag Up

- **R1 deck is due ~7 days from today (May 19).** kb-architect needs to produce a deck outline good enough that Kenneth can finish slides in 2-3 working days. If the agent over-scopes, the deck will slip.
- **Best Buy Canada SWAS store list is still approximate** per Matt's Andy follow-up. The tech spec must call this out as a Phase 1 blocker.
- **Amazon InfoSec re-engagement** for media-player scope has not yet been scheduled. PRD `open_questions.md` should escalate this.
- **CMS decision (A vs. B vs. third-party)** is genuinely open per the sensor/CMS response. The PRD should not pretend it's settled.
- **SWAS security issues** (CRITICAL hardcoded MQTT password, no admin UI auth) — Kenneth's tech spec for BBY Canada must not replicate these.

---

## Per-Ticket Implementation Steps

> Grounded in the repo exploration above. "Exists" = found in the repo. "Build" = net-new work.

---

### `86e1bpc5j` — Document Existing BrightSign Deployment Process
**Deliverable:** `deployment/existing_process.md` (presentation-ready for R1 slide ~6)
**Blocked by:** Nothing (documentation only, based on `~/dev/swas` inspection)

**What the existing process actually is (from repo):**

The current SWAS deployment is fully manual, with zero remote management:

1. Content is authored and compiled locally on a GP developer machine.
2. `client/webviewer/scripts/build-parallel.js` builds per-receiver JS bundles.
3. Built assets are SCP'd directly to the BrightSign player's local filesystem via SSH.
4. BrightSign plays content via `file://` path — no network fetch, no versioning.
5. LS5 sensor scripts (`lighting_and_proximity_script.js`) are also deployed manually to each LS5 node.
6. No BSN.cloud enrollment. No remote reboot. No firmware version tracking. No fleet visibility.
7. Status is unknown unless someone SSHes in or physically checks the unit.

**Implementation steps:**

1. Read `~/dev/swas` structure (already explored): document the SCP/file:// deployment pattern with a flow diagram.
2. Write `deployment/existing_process.md` with:
   - Section 1: How a store gets set up today (physical install + manual SCP)
   - Section 2: Day-to-day content updates (manual rebuild + SCP per receiver)
   - Section 3: What breaks and how you find out (you don't — someone calls)
   - Section 4: Fleet inventory gap (no centralized S/N list, no model tracking)
   - Mermaid diagram: `Developer → [build-parallel.js] → SCP → BrightSign (file://)` + branch for sensor script push to LS5
   - Explicit contrast callout: "What this means for 6,500 endpoints" (this process doesn't scale)
3. Add to R1 deck outline as Slide 5 "Where We Are Today" — use the diagram from this doc.

**Acceptance criteria:** `deployment/existing_process.md` exists, has the mermaid diagram, and a non-technical person reading it understands the manual-SCP limitation without needing to know what SCP means.

---

### `86e1bpbka` — Document Virgin BS Deployment + Workable Prototype
**Deliverable:** `deployment/virgin_process.md` + demo-able prototype on XT1144 (or HD1035)
**Blocked by:** Austin's BSN.cloud trial (for live demo); documentation can proceed without it

**What already exists in `~/dev/brightsign-app-deployment-setup-test` (commit `bb1e6ac`):**

The Partner App virgin onboarding flow is **already built and verified working**:

| File | Role | Status |
|------|------|--------|
| `SD_Card_Setup_Files/setup.json` | BSN.cloud token + S3 URL baked into SD card | Exists — hardcoded to Austin's trial + GP S3 |
| `SD_Card_Setup_Files/autorun.brs` | Device setup script (432 lines) — runs once on first boot | Exists |
| `SD_Card_Setup_Files/provisionScript.brs` | Downloads `autorun.zip` from S3 on first boot (396 lines) | Exists |
| `S3_content/autorun.brs` | Runtime OTA loop — polls `version.txt` every 30 min (161 lines) | Exists |
| `build.sh` | Creates `dist/autorun.zip` (pw: `"test"`) + `dist/version.txt` | Exists |

**Gaps to close before this is a "workable prototype" (not just a proof-of-concept):**

| Gap | Severity | Fix |
|-----|----------|-----|
| Zip password hardcoded as `"test"` | HIGH — insecure for any real demo | Parameterize via `BUILD_ZIP_PASSWORD` env var in `build.sh`; read from env at provision time |
| S3 bucket is GP-owned (`brightsign-app-hosting-test`, AWS `590183653052`) | BLOCKER for production; OK for R1 demo | For R1: document the bucket needs to move; for R2+: switch to Amazon's AWS account |
| BSN.cloud is Austin's trial (`AustinTestBSNCloud`) | BLOCKER for fleet work; OK for R1 demo | For R1: document account needs to move; escalate Austin's trial extension with Jay |
| WiFi credential handling untested (only wired tested) | MEDIUM — most stores use wired; WiFi needed for portability | Add WiFi SSID/password fields to `setup.json`; test on one device |
| BDeploy API pre-provisioning not built | Required for scale | Build `provision.sh` CLI (see `86e1bpgme` steps below) |
| Only 1 device tested; model unconfirmed | MEDIUM | Confirm tested model; re-test on XT1144 if different |
| No fallback if S3 unreachable at first boot | MEDIUM | Add retry loop (3×, 30s apart) in `provisionScript.brs` before failing |

**Implementation steps:**

1. Add `BUILD_ZIP_PASSWORD` env var to `build.sh` (replace hardcoded `"test"`).
2. Add WiFi config fields to `setup.json` schema; update `autorun.brs` to write WiFi credentials to player's network config if present.
3. Add S3 retry loop (3 attempts, 30-second backoff) in `provisionScript.brs` before halting.
4. Confirm test was on XT1144. If not, re-run on XT1144 (most common Phase 1 fleet model).
5. Capture a screen recording or photos of the full flow: power-on → SD card → BSN.cloud enrollment → S3 pull → content playing. These become R1 demo evidence.
6. Write `deployment/virgin_process.md` with:
   - Section 1: Pre-ship step — create BDeploy record via BSN.cloud API (S/N, location, autorun.zip URL)
   - Section 2: SD card preparation — `build.sh` → flash SD card with `setup.json` + scripts
   - Section 3: First boot sequence — `autorun.brs` runs, registers with BSN.cloud, calls `provisionScript.brs`, downloads from S3, launches content
   - Section 4: Steady-state — 30-min OTA loop, `version.txt` check, download new zip if version changed
   - Section 5: What this enables at scale — BDeploy record pre-created, player self-enrolls on first power-on, no tech on-site needed
   - Mermaid sequence diagram: `Factory → SD Card Prep → Store Power-On → BSN.cloud Enrollment → S3 Pull → Content Playing → 30-min OTA loop`

**Acceptance criteria:** `deployment/virgin_process.md` exists with sequence diagram; prototype repo has parameterized zip password + S3 retry; at least 1 device confirmed working on XT1144 or HD1035; demo evidence captured.

---

### `86e1bp68j` — R1 Architectural Deck (due 2026-05-19 🔴)
**Deliverable:** `decks/r1_outline.md` (slide-by-slide outline for Kenneth to build into slides)
**Depends on:** `86e1bpc5j` and `86e1bpbka` complete (or at least drafted)
**Audience:** mix of non-technical (Amazon ops) + technical (BrightSign engineering) — balance required

**Slide outline:**

| # | Title | Key points | Source |
|---|-------|-----------|--------|
| 1 | Cover | "GP + Amazon: Managed Media Player Fleet — Phase 1 Architecture" | — |
| 2 | The Challenge | 17,700+ endpoints across 5 retailers; today: zero centralized management, zero sensor visibility, manual everything | Proposal §1 |
| 3 | What Amazon Has Today | Map of fleet: BBY US Play Table (~6,500), BBY Canada SWAS (~306), Lowe's, NFM, Brandsmart; no monitoring, no remote management | Fleet calculator |
| 4 | GP's Approach | BSN.cloud bsn.Control (free) as the device management layer; Partner App mode for content delivery; GP Platform as the single pane of glass | Proposal + `setup.json` |
| 5 | How Players Get Content Today | Manual SCP / USB process; why it doesn't scale; what breaks when something goes wrong | `deployment/existing_process.md` |
| 6 | The New Deployment Flow | Partner App mode: SD card → BSN.cloud enrollment → S3 pull → 30-min OTA loop; field tech does zero post-install work | `deployment/virgin_process.md` |
| 7 | Live Demo / Evidence | Photo or screen recording of prototype running on XT1144: power-on → content playing in under N minutes | Prototype demo |
| 8 | What We're Building (Phase 1) | Play Table BBY US enrollment, SWAS BBY Canada, GP Platform + Dashboard, sensor health monitoring; CMS decision pending | `core_vs_stretch.md` |
| 9 | Timeline + Next Steps | R1 → R2 → SOW close → Phase 1 delivery milestones; open items needing Amazon input (AWS account, store list, InfoSec) | `core_vs_stretch.md` sequencing |
| 10 | Open Questions | BSN.cloud trial → Amazon account transition; BBY Canada store list; CMS Option A vs. B; InfoSec re-engagement | `open_questions.md` |

**Implementation steps:**

1. Confirm `deployment/existing_process.md` and `deployment/virgin_process.md` are done (or far enough to pull diagrams from).
2. Write `decks/r1_outline.md` using the slide table above. Flesh out each slide's 3–5 bullet points.
3. For Slide 7 — ensure the prototype demo evidence exists (photo/video from `86e1bpbka`).
4. Review with the filter: "Would a BBY store manager understand slides 2–5 without a BrightSign background?" If yes, ship.

**Acceptance criteria:** `decks/r1_outline.md` has all 10 slides with bullet points; Kenneth can use it to build slides in < 3 hours; Slide 7 has real evidence (not placeholder).

---

### `86e1bpk74` — High-Level Deliverables Breakdown (due 2026-05-22)
**Deliverable:** `ticket_breakdown.md` — client-facing language consolidating what GP will deliver
**Blocked by:** Nothing (reference Matt's PDF + the proposal)
**Note:** Matt's PDF is attached to the ClickUp ticket — Kenneth must read it before writing this.

**What this needs to contain:**

A clean, jargon-minimal list of what GP contractually delivers in Phase 1, organized by workstream. Not technical specs — "client-facing language" means phrases like "Remote device monitoring for 6,500 Best Buy Play Table players" not "BSN.cloud bsn.Control API polling + webhook integration."

**Implementation steps:**

1. Read Matt's PDF (attached to `86e1bpk74` in ClickUp).
2. Cross-reference with the proposal, Andy follow-up, and sensor/CMS response for scope completeness.
3. Write `ticket_breakdown.md` with two parts:
   - **Part A: Client-Facing Deliverables** — a numbered list of what ships in Phase 1, in plain language, organized by category (Platform, Device Management, SWAS BBY Canada, Play Table BBY US, Sensor Monitoring, Dashboard, CMS)
   - **Part B: Ticket Map** — table mapping each deliverable to the ClickUp ticket that owns it; flag NEW tickets that need to be created
4. Flag the 3 still-open decisions that affect contract scope: CMS Option A vs. B, BBY Canada final store count, Amazon InfoSec scope.

**Acceptance criteria:** `ticket_breakdown.md` Part A could be pasted into the SOW without technical rewrites; every deliverable in Part A maps to a ticket in Part B; open decisions are clearly flagged.

---

### `86e1bp89c` — R2 Architectural Deck (due 2026-05-25, co-assigned Austin Humes)
**Deliverable:** `decks/r2_outline.md`
**Depends on:** R1 feedback from the May 19 meeting (add as placeholder); `prd.md`, `tech_spec.md`, `cms_options.md` complete
**Audience:** same as R1 but with more engineering depth — Austin will co-present the BrightSign-specific portions

**Key additions over R1:**

| Section | Content | Source |
|---------|---------|--------|
| R1 Feedback Response | Slide incorporating responses to questions from May 19 | Meeting notes (placeholder until May 19) |
| Full System Architecture | Mermaid diagram: GP Platform ↔ BSN.cloud Control ↔ Amazon AWS S3 ↔ BrightSign fleet ↔ Sensors ↔ Dashboard | `tech_spec.md` §1 |
| GP Platform Components | Component breakdown: BSN.cloud integration layer, content publishing pipeline, alerting engine, dispatch system | `tech_spec.md` §2 |
| Sensor Health Monitoring | How GP detects data gaps per-sensor (Darko/Outform/Lynx) before Amazon knows; the S3 pipeline instrumentation | `tech_spec.md` §8 |
| Dashboard Demo | Screenshots from `bsn-dashboard`: device list, health badges, screenshot viewer, Slack alerts | `~/dev/bsn-dashboard` |
| CMS Decision | Side-by-side: Option A (bsn.Content, Amazon pays BrightSign) vs. Option B (GP Partner App CMS); recommendation | `cms_options.md` |
| SLA Tiers + Alerting | Alert → ticket → dispatch latency by tier; dispatch-ready format for 130 market managers | `tech_spec.md` §9 |
| Phase 1 Rollout Timeline | Gantt or milestone chart: May → Nov 2026 | `core_vs_stretch.md` sequencing |
| Phase 2 Preview | S1 (AI content verification via Bedrock), S4 (multi-device), Phase 2/3 fleet (Lowe's, Brandsmart) | `core_vs_stretch.md` stretch section |

**Implementation steps:**

1. After May 19 R1 meeting: capture feedback + questions into a notes file; feed into slide 2 ("Since R1…").
2. Generate or export Mermaid system context diagram from `tech_spec.md` for the architecture slide.
3. Take screenshots of `bsn-dashboard` for the dashboard demo slide.
4. Write `decks/r2_outline.md` with all sections above.
5. Sync with Austin on BrightSign-specific slides (models, BDeploy API, fleet org questions).

**Acceptance criteria:** `decks/r2_outline.md` covers all sections above; CMS decision is presented clearly (not deferred again); dashboard screenshots are real (not wireframes); Austin has reviewed BrightSign-specific slides.

---

### `86e1bpgme` — Initial Deployment System for New BS Players (~June 4)
**Deliverable:** `tech_spec.md` §6 (Deployment Subsystem) + field runbook + `provision.sh` CLI scaffolding
**Depends on:** `86e1bpbka` prototype working; BrightSign contact for BDeploy API rate limit questions; Amazon AWS account

**What this is:** scaling the proven Partner App prototype from a 1-device proof-of-concept to a repeatable provisioning system for 1,300+ players across Phase 1.

**Architecture decisions to make and document:**

| Decision | Options | Constraint |
|----------|---------|-----------|
| BDeploy pre-provisioning trigger | Manual CLI (`provision.sh`) vs. GP Platform API call | Start with CLI; automate later |
| Per-player S3 URL structure | Flat: `/{S/N}/autorun.zip` vs. hierarchical: `/{retailer}/{store}/{fixture}/autorun.zip` | Hierarchical — easier to manage at store/fixture level; supports bulk content updates |
| SD card master images | One per model (XT1144, HD1035, HS5, LS5) with parameterized `setup.json` | One master per model; `setup.json` injected at flash time by `provision.sh` |
| Content publish pipeline | Manual `build.sh` + `aws s3 cp` vs. GitHub Actions CI | GitHub Actions on merge to `main` for the autorun.zip build + S3 publish |
| Zip password management | Env var only vs. secrets manager | AWS Secrets Manager (since this is on Amazon's AWS account) |
| Swap/replacement identity | S/N-based vs. fixture-position-based | Fixture-position as stable identity; S/N updated in BDeploy record when unit is swapped |
| Transfer-existing-player flow | SD card swap vs. remote re-provision | SD card swap for now (no BSN.cloud on existing SWAS players); plan remote re-provision for Phase 2 |

**Implementation steps:**

1. **Write `tech_spec.md` §6 — Deployment Subsystem** covering:
   - Current state (manual, no remote management) — link to `deployment/existing_process.md`
   - Virgin onboarding flow — link to `deployment/virgin_process.md`
   - New Initial Deployment System: BDeploy pre-provisioning, S3 content pipeline, check-in cadence, fallback, swap handling
   - Mermaid diagram: `provision.sh → BSN.cloud BDeploy API → SD Card Build → Ship to Store → First Boot → BSN.cloud → S3 → Content → OTA loop`

2. **Build `provision.sh` scaffolding** in `~/dev/brightsign-app-deployment-setup-test`:
   - Input: `--serial <S/N> --store <store_id> --fixture <fixture_type> --model <XT1144|HD1035|HS5|LS5>`
   - Step 1: Call BSN.cloud BDeploy API to create/update the device record
   - Step 2: Generate device-specific `setup.json` (token + S3 URL for that fixture)
   - Step 3: Output SD card directory ready to flash (copy `setup.json` + `autorun.brs` + `provisionScript.brs`)
   - Use env vars: `BSN_CLIENT_ID`, `BSN_CLIENT_SECRET`, `BSN_NETWORK_ID`, `S3_BUCKET`, `ZIP_PASSWORD`

3. **Build S3 publish pipeline** extension to `build.sh`:
   - Add `--push` flag: after building `dist/autorun.zip` + `dist/version.txt`, run `aws s3 cp dist/ s3://$S3_BUCKET/$FIXTURE_PATH/ --recursive`
   - Add GitHub Actions workflow: on push to `main`, build + push to S3 content path

4. **Write field runbook** (a section in `tech_spec.md` or a separate `deployment/field_runbook.md`):
   - Step-by-step for a GP ops person: how to provision a new player, prepare the SD card, ship to store
   - Step-by-step for a field tech: what to do when the player arrives (just power it on)
   - Troubleshooting: player not enrolling (BSN.cloud network not set up), player not pulling content (S3 URL wrong, check version.txt), player offline after update (check BSN.cloud device status)

5. **Open questions to resolve with BrightSign contact (Austin has the contact):**
   - BDeploy API rate limits — how many create/update calls per minute?
   - Can BDeploy records be created before the physical player is registered? (Pre-provisioning model)
   - Does the free bsn.Control tier support BDeploy API at the scale of 6,500 players?
   - What's the recommended way to organize players into BSN.cloud "networks" at retailer/store granularity?

**Acceptance criteria:** `tech_spec.md` §6 is complete with mermaid diagram; `provision.sh` scaffolding exists with CLI flags documented; S3 publish pipeline runs end-to-end on the test bucket; field runbook written; BrightSign API questions documented in `open_questions.md`.

---

## Missing Tickets to Propose in `ticket_breakdown.md`

The six assigned tickets cover deployment + decks but leave significant Phase 1 work untracked. The following should be proposed as new tickets when writing `ticket_breakdown.md`:

| Proposed Title | Why it's missing | Urgency |
|----------------|-----------------|---------|
| BSN.cloud bsn.Control GP Platform Integration | `bsn-dashboard` implements this but it's not formalized as a Platform component; needs persistent DB, multi-network, SLA config | High — blocks device monitoring |
| Operations Dashboard MVP (extend `bsn-dashboard`) | `bsn-dashboard` is ~80-90% built but missing: PostgreSQL persistence, SLA tier rules, escalation, sensor health views, multi-network | High — demo at R2 |
| SWAS BBY Canada Security Fixes | CRITICAL: hardcoded MQTT password (`lighting_script.js:34`), unauthenticated admin UI (`server/admin/app.js`) must be fixed before ANY BBY Canada deployment | CRITICAL — blocks all SWAS work |
| SWAS BBY Canada Extension (6 stores) | Replicate NFM SWAS pattern for BBY Canada; needs confirmed store list | High — Phase 1 contract |
| Play Table BBY US Bulk Enrollment Design | BDeploy API for 6,500 players at scale; bulk provisioning workflow | High — largest Phase 1 surface |
| Per-Sensor Health Monitoring — S3 Gap Detection | Instrument existing S3 pipeline to detect per-sensor data gaps; Darko/Outform/Lynx in single view | High — key differentiator per Andy |
| CMS Layer Implementation (Option A or B bridge) | CMS decision locked → implement; if undecided, deploy Option A as bridge | Medium — needed before content updates |
| Amazon AWS Account + Infrastructure Setup | Provision Amazon's S3 bucket, IAM roles for GP Platform access, move off GP-owned `brightsign-app-hosting-test` | BLOCKER — owned by Amazon |
