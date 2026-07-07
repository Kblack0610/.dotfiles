---
root: true
targets: ["*"]
description: "Shared global rules for Codex, Claude, Gemini, and OpenCode"
globs: ["**/*"]
---

# Shared AI Assistant Rules

This dotfiles repository is the source of truth for shared AI assistant rules and MCP configuration.

## Operating Model

- Keep reusable shared rules and MCP definitions in `~/.dotfiles/.config/rulesync-global/`.
- Keep machine-local runtime state in tool-specific home directories such as `~/.codex`, `~/.claude`, `~/.gemini`, and `~/.config/opencode`.
- Do not automate edits to auth tokens, history, logs, sqlite databases, or other ephemeral runtime state.

## Workflow Expectations

- Plan before implementation for non-trivial work.
- Re-check existing plans in `~/.agent/plans/{project}/` before starting implementation.
- Prefer elegant fixes over additive hacks, but do not over-engineer simple changes.
- After a user correction, capture the lesson in `~/.agent/lessons/{project}.md`.
- Before adding a new dependency, UI framework, or architectural pattern, grep the lessons file for that keyword. If a lesson prohibits it, stop and discuss with the user.

### Session Preflight (before implementation)

Before starting any implementation work, run these three cheap checks:
1. `ls ~/.agent/plans/{project}/` — read any existing plan; state whether the current task aligns
2. `tail -20 ~/.agent/lessons/{project}.md` — review recent lessons for relevant constraints
3. `git log --oneline -5` + `gh pr list --state=all --limit=5` — check if the task is already done or in-flight

Only escalate to Explore agents or multi-tool investigations after these checks are inconclusive.

## Verification

- Do not mark work complete without verification that matches the change.
- Run the smallest credible validation that proves the change.
- Report what was verified and what could not be verified.

## Writing Style (artifact prose)

Applies to durable, outward-facing writing — READMEs, commit/PR messages, docs, code comments. Conversational response tone is governed separately (per-project feedback memory).

- Write as a technical architect documenting work, not marketing it. State what a thing is and does; let the reader judge. No selling.
- Cut intensifiers and filler that carry no information: "even", "entirely", "fully", "completely", "simply", "just", "seamless", "powerful", "robust", "blazing-fast". If deleting the word doesn't change the meaning, delete it.
- Lead with the fact or the imperative — no throat-clearing ("It's worth noting that…", "Basically…").
- Prefer concrete, verifiable claims over adjectives: "no Tree-sitter parser required" beats "incredibly lightweight". State caveats plainly instead of hiding them.
- Match the surrounding document's voice and density.
- Plain ASCII only. No fancy Unicode symbols: no em dash or en dash (use a regular hyphen, comma, or colon), no section sign (write "Section"), no arrows (write "->"), no >=, <=, x-times, middot, ellipsis, subscripts (write "T0"), or emoji. This applies to anything mirrored into ClickUp or Google Docs too. Why: these are the tells that make a doc read as machine-written, and they render badly in some viewers.
- Do not invent label schemes (for example "F1..F27" IDs). Refer to things by the source document's own names and numbering.
- Do not hard-wrap prose or bullets to a column width. Write each paragraph, bullet, and blockquote line as one physical line so renderers (ClickUp, GitHub) soft-wrap. Tables stay one row per line. Why: a hard newline mid-sentence becomes a forced line break in soft-wrapping viewers.

## Artifact Placement

Where files land matters. Default to ephemeral; only commit when the artifact is clearly a tracked repo asset.

- **Ephemeral / verification screenshots and dumps** (from `/verify`, `sc:manual-test`, Playwright debug runs, ad-hoc "show me what it looks like", logcat captures, scratch JSON) → `$TMPDIR` or `/tmp/claude-screenshots/`. Never the repo root, never staged, never committed.
- **Intentional artifacts** → the repo's canonical location:
  - Docs/README images → `docs/images/` (or whatever the repo already uses)
  - E2E visual baselines → the test framework's snapshot dir (`e2e/__screenshots__/`, `tests/__snapshots__/`, Playwright `test-results/`)
  - Design assets → `assets/` or `public/`
- Only commit a screenshot or generated artifact if the user explicitly asks, or it clearly belongs to one of the tracked locations above. When in doubt, drop it in `/tmp/` and link to it.

## Infrastructure Questions

- For infrastructure, cluster, deployment, ingress, or Kubernetes status questions, identify the target environment explicitly before answering.
- Do not assume a default production cluster when multiple clusters may exist.
- Prefer repo-local infrastructure docs and manifests for project-specific operational truth, then verify against the live target context when access is available.
- If a repo distinguishes between a navigation hub and domain docs, treat the domain docs as the source of truth for operational details.

## Prefer skills over raw tooling and MCPs

When a skill exists for an operational domain, use it instead of hand-rolling commands or reaching for the equivalent MCP. The skill encodes the current environments, conventions, and safety checks:

- Notes / `~/.notes` journal → `notes-system` skill (do not hand-write entries into `~/.notes/journal/`)
- Kubernetes (home-k3s, do-nyc3-placemyparents-k8s-prod, k3d-local) → `k8s-ops` skill
- Cloudflare DNS / tunnels for kennethblack.me, blacknbrownstudios.com, binks.chat, kblack.dev → `cloudflare-ops` skill
- Forgejo on home-k3s (git.kblab.me) → `forgejo-ops` skill
- GitHub (PRs, issues, CI, releases) → `gh-workflows` skill (preferred over any GitHub MCP)
- Bitbucket Cloud (PRs, pipelines, issues, code search) → `bitbucket-ops` skill (enterprise-safe)

If a skill doesn't yet exist for a domain you touch repeatedly, propose one rather than inlining the procedure here.

## Agent Delegation

Non-trivial implementation work flows through the `kb-*` agent pipeline:

1. `kb-product-owner` — turns ambiguous asks into Product Briefs
2. `kb-architect` — turns briefs into technical specs / conducts audits
3. `kb-developer` — implements from specs with tests and docs
4. `kb-qa` — verifies quality gates before merge

For isolated Linear tickets, use `kb-linear-implementer` (fetch ticket → implement → PR, isolated context).

Entry-point skills: `/kb:workflow` (full flow), `/kb:ticket` (Linear-driven), `/kb:implement` (feature → PR).

The kb Phase-0 ticket step is **tracker-agnostic and MCP-first**: the active system (verbs `system|resolve-epic|claim|create|done|pr-line`) is selected per-repo from `project-map.json` `trackers` (vikunja/jira/clickup/linear/notion/local). Two write modes — drive the system's MCP per `docs/adapters/<system>.md` when connected, else the `ticket` CLI (on PATH; token+curl) as the headless/CI fallback. Never hard-code a ticketing system. Contract + adapters + templates: `~/.dotfiles/.local/src/ticket/docs/contract.md`.

For parallel code exploration or independent research queries, delegate to `Explore` agents.

For regulated/sensitive-data questions (PHI/HIPAA, PII, GDPR, FTC/state health-privacy, SOC2, vendor BAAs/DPAs, covered-product coverage, "are we compliant?"), use the `compliance` skill (dated reference: regulatory-scope decision tree + covered-product matrix + verify method) and/or the `compliance-counsel` agent (Vera ⚖️). **Verify coverage against the vendor's live docs / the primary regulation — never from memory** (cite + date the source); separate technical fact from a lawyer's ruling; determine regulatory scope first; name the human-counsel / BAA gate. Advisory only — never satisfy a legal/approval gate or pose as the lawyer.

## Project Mapping

- `gheegle`, `ghee-sheets`, `ghee-*` -> `~/.agent/plans/gheegle/`
- `shack`, `search` -> `~/.agent/plans/shack/`
- `dotfiles`, `waybar`, `zellij` -> `~/.agent/plans/dotfiles/`
- `binks-agent`, `orchestrator` -> `~/.agent/plans/binks-agent/`
- `bnb-platform`, `monorepo` -> `~/.agent/plans/bnb-platform/`

## Compact Handoff

Preserve the modified files, verification results, key architectural decisions, task status, next step, active plan location when one exists, and recurring error patterns with their fixes.
