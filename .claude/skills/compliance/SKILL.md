---
name: compliance
description: >-
  Reference lookup for regulated-data compliance — the regulatory-scope decision tree
  (covered entity vs business associate vs non-HIPAA regimes like FTC/CMIA/MHMDA), the
  method for verifying whether a vendor/product is HIPAA/SOC2/GDPR-covered under a BAA,
  and a DATED snapshot of cloud-vendor covered-product coverage (DigitalOcean, AWS, GCP).
  Use when you need to look up "which regime applies", "how do I confirm <vendor> covers
  <product>", or a quick covered/not-covered hint before a deeper check — for PHI/HIPAA,
  PII, GDPR, BAA/DPA, data-residency, or "are we compliant?" questions. This is the
  reference card; the `compliance-counsel` agent is the one that REASONS about a specific
  situation. Do NOT treat this skill's vendor matrix as authoritative — it is a dated
  snapshot to be re-verified. Do NOT use for code security review (that's security-engineer)
  or for definitive legal advice (that's qualified human counsel).
---

# compliance

Reference card for handling regulated or sensitive data. The `compliance-counsel` agent does the
*reasoning*; this skill is the *lookup* it (and you) pull from. Keep it lean and keep it dated.

## ⚠️ Lead rule — this is a dated snapshot, not the source of truth

**Re-verify every coverage claim below against the vendor's live BAA / covered-products page
(or the primary regulation) before relying on it.** Vendor coverage changes silently and without
notice — DigitalOcean removed Managed Databases from its HIPAA-covered list in Jul 2024 with no
fanfare. A confident-but-stale "yes it's covered" is the most dangerous output this skill can
produce. Cite the source *and the date you checked it* in any answer that leans on this card.

## Regulatory-scope decision tree (determine this FIRST)

Scope drives the entire workload — get it right before designing anything. Walk these in order:

1. **Are we a HIPAA covered entity?** A covered entity is a health plan, clearinghouse, or a
   provider that transmits HIPAA *standard electronic transactions* (claims/eligibility/billing
   to insurers). If the product never does those, it likely is **not** a covered entity directly.
2. **Are we a HIPAA business associate (BA)?** If our customers are covered entities (e.g. home-care
   providers that bill Medicare/Medicaid) and we store/route/process PHI *on their behalf*, we are
   plausibly a **BA** — and those customers will require a signed **BAA** from us to onboard. This
   is the most common back-door into HIPAA for B2B health platforms.
3. **Even if HIPAA doesn't bite, do other regimes apply?** They usually do for health/wellness data:
   - **FTC Act + Health Breach Notification Rule** — enforced against non-HIPAA health apps
     (GoodRx, BetterHelp). Applies regardless of covered-entity status.
   - **State consumer-health laws** — CA **CMIA**, WA **My Health My Data Act** (broad "consumer
     health data" definition, private right of action), plus general privacy laws (CCPA/CPRA, GDPR).
4. **Conclusion to validate with counsel.** "Not a HIPAA covered entity" ≠ "unregulated." Build to
   the covered-infra + signed-contract standard regardless, because (a) B2B customers will demand a
   BAA and (b) FTC/state regimes apply anyway. Let counsel confirm scope — it can *reduce* the work,
   but don't bet the architecture on a free pass.

## How to verify a vendor's coverage (the method)

1. Find the vendor's **BAA** (HIPAA) / **DPA** (GDPR) / compliance page and its **covered-products
   list** — the named list of services the agreement actually covers.
2. Confirm the **specific product** you're using is on that list. "Vendor X is HIPAA-capable" ≠
   "the product we use is covered." The gap is almost always a specific service being excluded.
3. Confirm a signed agreement is **executed**, not merely available.
4. **Cite the source URL + the date you checked.** Record it on the project's compliance register
   (`docs/compliance/*`), not just in chat.

## Cloud-vendor covered-product snapshot (DATED — re-verify)

> Snapshot as of **2026-06** for HIPAA BAA coverage. **Verify against each vendor's live page.**

| Vendor | Covered ✅ | NOT covered ❌ | Source |
|---|---|---|---|
| **DigitalOcean** | Spaces (object storage), Droplets, Kubernetes (DOKS), Volumes, Load Balancers, VPC | **Managed Databases (incl. Managed PostgreSQL)** — excluded since Jul 2024; "run DBs on Droplets per HIPAA architecture guide" | digitalocean.com/security/shared-responsibility-model-managed-databases |
| **AWS** | Most HIPAA-eligible services incl. RDS/Aurora, S3, EKS, EC2 (see AWS HIPAA-eligible-services list) | Non-eligible services per the live list | aws.amazon.com/compliance/hipaa-eligible-services-reference |
| **GCP** | Cloud SQL, GCS, GKE, Compute, and the broad "covered products" list under the Google Cloud BAA | Anything outside the covered-products list | cloud.google.com/security/compliance/hipaa |

**Takeaway pattern:** object storage and raw compute/k8s tend to be covered; the trap is *managed
databases* and newer/niche services. Always check the database service explicitly — that's where
most of the structured PHI lives.

## What's regulated is usually the structured data, not just the files

When mapping where sensitive data lives, don't stop at the obvious file blobs. For a care/health
platform the highest-regulated asset is typically structured rows — names + dates of birth +
medical conditions + medications + cognitive status, sitting together in the primary database —
plus free-text fields (care notes, messages) and any notifications/logs that echo them. File
uploads are often the *best*-handled PHI because blobs land in covered object storage. Map the
real data flow before recommending controls.

## Related

- `compliance-counsel` agent — the reasoning persona that applies this card to a specific situation
- `security-engineer` agent — code-level vulnerability review (distinct concern)
- A project's `docs/compliance/*.md` — project-specific control mappings, contingency plans,
  subprocessor/BAA register (the auditor-facing source of truth)
- Not legal advice — scope and sufficiency determinations belong to qualified human counsel
