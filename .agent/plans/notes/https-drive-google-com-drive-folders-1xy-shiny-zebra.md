# Plan — Amazon Media Player Fleet: PRD → Tech Spec → Ticket Breakdown

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

**Google Drive folder "Media Player RFP" (`1XyrCZgQySLZ0hZCX2AXSA7lh1FTQf-m1`):**
- `amazon-media-player-proposal.md` (fileId `1qD5xZTa6g1wi73-4cpDQm1ZYAxak7HOj`, 57KB) — the canonical proposal
- `response-to-andy-followup-questions-april.md` (fileId `1CwXfztLWLydAGlyJboRSTot6riVCa2UC`) — InfoSec, support model, parameter flexibility, 2026 payment schedule
- `response-to-andy-sensor-pricing-and-cms.txt` (fileId `1QIWxTSTxi0QlCCvX62jDcxfpKvDGH5lu`) — per-sensor pricing, CMS Option A/B walkthrough
- `Questions For Brightsign` (Google Doc, fileId `1fSRn8Zrtdt1Apvv6viOpaJX4Hh2GeyIRkokM6lgavn8`) — BS player model inventory, publishing modes, fleet onboarding open questions
- `AMZ GP Fleet Calculator` (Sheet, fileId `1nXYjGtBtpPK9iXOprVkdrJ7O7DBn14XkTwPraNwpdJA`) — 2026/2027/2028 cost model
- `AMZ Media Player Fleet Project Model` (Sheet, fileId `14rxATYIPTnKJu-c2YsIgDPla9pY-hjlPVpQwitQ7dfo`) — project planning model

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
