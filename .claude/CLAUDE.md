Workflow Orchestration

1. Plan Mode Default

    Enter plan mode for ANY non-trivial task (3+ steps or architectural decisions)
    If something goes sideways, STOP and re-plan immediately - don't keep pushing
    Use plan mode for verification steps, not just building
    Write detailed specs upfront to reduce ambiguity

2. Subagent Strategy to keep main context window clean

    Offload research, exploration, and parallel analysis to subagents
    For complex problems, throw more compute at it via subagents
    One task per subagent for focused execution

3. Self-Improvement Loop

    After ANY correction from the user: update `~/.agent/lessons/{project}.md` with the pattern
    Write rules for yourself that prevent the same mistake
    Ruthlessly iterate on these lessons until mistake rate drops
    Review lessons at session start for relevant project
    Before adopting a new dependency, UI framework, or architectural pattern, grep the lessons file for that keyword — if a lesson prohibits it, stop and discuss
    Skill-candidate detection: when the same multi-step manual workflow recurs 3+ times (across sessions, or once within a session if it's clearly going to recur), propose drafting it as a skill at `~/.dotfiles/.claude/skills/{name}/SKILL.md`. Surface the candidate, confirm scope and naming with the user, then write the SKILL.md. Don't auto-create skill files. Idea adapted from rebelytics/one-skill-to-rule-them-all (CC BY 4.0).

4. Verification Before Done

    Never mark a task complete without proving it works
    Run the smallest credible validation that matches the change
    Diff behavior between main and your changes when relevant
    Ask yourself: "Would a staff engineer approve this?"
    Report what was verified and what could not be verified
    Run tests, check logs, demonstrate correctness

5. Demand Elegance (Balanced)

    For non-trivial changes: pause and ask "is there a more elegant way?"
    If a fix feels hacky: "Knowing everything I know now, implement the elegant solution"
    Skip this for simple, obvious fixes - don't over-engineer
    Challenge your own work before presenting it

6. Autonomous Bug Fixing

    When given a bug report: just fix it. Don't ask for hand-holding
    Point at logs, errors, failing tests -> then resolve them
    Zero context switching required from the user
    Go fix failing CI tests without being told how

Task Management

    Plan First: Write plan to `~/.agent/plans/{project}/` with checkable items
    Re-check Existing Plans: Read `~/.agent/plans/{project}/` before starting implementation
    Verify Plan: Check in before starting implementation
    Track Progress: Mark items complete as you go
    Explain Changes: High-level summary at each step
    Document Results: Add review to `~/.agent/plans/{project}/`
    Capture Lessons: Update `~/.agent/lessons/{project}.md` after corrections

Core Principles

    Simplicity First: Make every change as simple as possible. Impact minimal code.
    No Laziness: Find root causes. No temporary fixes. Senior developer standards.
    Minimal Impact: Changes should only touch what's necessary. Avoid introducing bugs.
    Auth-State Safety: Do not automate edits to auth tokens, history, logs, sqlite databases, or other ephemeral runtime state.

---

## Workflow Expectations

- Do not automate edits to auth tokens, history, logs, sqlite databases, or other ephemeral runtime state.
- Plan before implementation for non-trivial work.
- Re-check existing plans in `~/.agent/plans/{project}/` before starting implementation.
- Prefer elegant fixes over additive hacks, but do not over-engineer simple changes.
- After a user correction, capture the lesson in `~/.agent/lessons/{project}.md`.
- Before adding a new dependency, UI framework, or architectural pattern, grep the lessons file for that keyword. If a lesson prohibits it, stop and discuss with the user.

### Session Preflight

The SessionStart hook injects plans, last-20 lessons, recent commits, and open/recent PRs into the conversation as `additionalContext`. Use that — don't re-run those commands. Escalate to Explore agents only if the injected context is inconclusive.

### Plan Lifecycle

Plan-mode plans are written to `~/.claude/plans/{slug}.md`. After every Stop, `stop-post.d/85-sync-plans.sh` copies any plan touched in the last 24h into `~/.agent/plans/{project}/`. The next SessionStart preflight then lists those files. The loop:

  plan-mode write → stop-hook copy → next session preflight injects

When you act on an existing plan, **update the plan file** — mark items complete, append a "Results" section. The agent-plans copy is a cache; the source-of-truth file lives in `~/.claude/plans/`. Edit there. Stale subdirs in `~/.agent/plans/` get archived by `~/.dotfiles/.config/shared-hooks/archive-stale-plans.sh` (run manually).

## Operating Model

- Keep reusable shared rules and MCP definitions in `~/.dotfiles/.config/rulesync-global/`.
- Keep machine-local runtime state in tool-specific home directories such as `~/.codex`, `~/.claude`, `~/.gemini`, and `~/.config/opencode`.

## Memory Routing

| Knowledge type | Where it lives | How it gets recalled |
|---|---|---|
| User prefs (tooling choices, repo paths, workflow style) | self-hosted mem0 at `mem0.kblab.me` (`user_id=kblack0610`) | `mem0-ops` skill — curl `/search?query=...&user_id=kblack0610` early in any session that touches user prefs |
| Cross-project facts ("project A uses X", client conventions) | self-hosted mem0 (`user_id=kblack0610`, optional `agent_id=<project>`) | Same — `mem0-ops` skill |
| Project-specific corrections / lessons | `~/.agent/lessons/{project}.md` | SessionStart hook injects last-20 automatically; no tool call needed |
| Project front door (decisions + why, key URLs, links to every layer) | `~/.agent/anchors/{project}.md` | SessionStart hook injects the whole anchor at turn 1, first; refresh the auto-block with the `project-index` skill |
| Workflow rules (this file) | `~/.claude/CLAUDE.md`, `AGENTS.md` for non-Claude tools | Auto-loaded |
| Project runbook docs (auth flow, deploy steps) | Project repo markdown, git-tracked | Read directly when working in that repo |
| Plans + evals | `~/.agent/plans/{project}/`, `~/.agent/evals/{project}/` | SessionStart hook lists plans; eval format documented below |
| Session wrap-ups (narrative "what happened") | `~/.agent/sessions/{project}/<date>-wind-down.md` | Written by the `wind-down` skill; runtime axis, git-tracked. Read directly |
| Consolidated memory (nightly distillation) | `~/.agent/dreams/{project}/` (`DREAMS.md` diary, `mem0-queue.md`) | Written by **Dreaming** (`/dream` + `agentctl@dream` at 03:00); SessionStart injects the latest Deep-sleep digest. Runbook: `.config/agentctl/DREAMING.md` |
| Project release/status bus + human↔agent comms | `~/.notes/lab/projects/current/{name}/summary.md` (two-region: `## → For the agents` + `## ← Release & status feed`) | The slow, durable, multi-device BUS between `~/.agent` runtime and in-repo CHANGELOG. Agents post the feed via the **`lab-sync`** skill (`/lab-sync` + weekly `agentctl@lab-sync`, deterministic); you post comments/tasks under `## → For the agents` and the SessionStart preflight injects them at turn 1. `<!-- canonical: NAME -->` maps lab name → agent/repo name. |
| Skill knowledge | `~/.claude/skills/` | Auto-loaded when skill is invoked |

When writing memories, prefer mem0 (via the `mem0-ops` skill) for facts that should ride across projects/tools and lessons for project-specific corrections. Don't write project runbooks to memory — those belong in the project repo. **Dreaming** is the consolidation layer over the rest: nightly it scores the eval/lesson/session corpus and promotes durable signal into lessons + `memory/` (local, auto) and a human-gated `mem0-queue.md` (cross-project) — it never auto-posts to mem0. `nightly-sync` (23:00) ingests notes→mem0; `dream` (03:00) reflects on the agent's own work; `lab-sync` (weekly) mirrors git + `~/.agent` into the lab project bus. See `.config/agentctl/DREAMING.md`. **Memory layering:** anchor (deterministic index, always injected) → lessons (patterns) → mem0 (cross-project semantic recall) → lab bus (human-facing release + comms). The anchor index and mem0 are **complementary, both kept** — the index is deterministic/always-present, mem0 is fuzzy/cross-project/can-be-down.

## Infrastructure Questions

- For infrastructure, cluster, deployment, ingress, or Kubernetes status questions, identify the target environment explicitly before answering.
- Do not assume a default production cluster when multiple clusters may exist.
- Prefer repo-local infrastructure docs and manifests for project-specific operational truth, then verify against the live target context when access is available.
- If a repo distinguishes between a navigation hub and domain docs, treat the domain docs as the source of truth for operational details.

## Prefer skills over raw tooling and MCPs

Use a skill instead of hand-rolling commands or reaching for the equivalent MCP when one exists:

**Infra / ops**
- `k8s-ops` — Kubernetes (home-k3s, do-nyc3-placemyparents-k8s-prod, k3d-local)
- `cloudflare-ops` — DNS/tunnels for kennethblack.me, blacknbrownstudios.com, binks.chat, kblack.dev
- `forgejo-ops` — git.kblab.me on home-k3s
- `gh-workflows` — GitHub PRs, issues, CI, releases (preferred over any GitHub MCP)
- `bitbucket-ops` — Bitbucket Cloud PRs, pipelines, issues, code search (enterprise-safe; preferred over raw API calls)
- `adb-ops` — Android debug bridge / emulator / APK install / logcat

**Notes / memory**
- `notes-system` — `~/.notes` journal (do not hand-write entries into `~/.notes/journal/`)
- `mem0-ops` — cross-project, cross-tool long-term memory at `mem0.kblab.me`
- `project-index` — refresh a project's anchor (`~/.agent/anchors/{project}.md`), the per-project memory/index.md front door the SessionStart hook injects at turn 1
- `lab-sync` — refresh the **lab project bus** (`~/.notes/lab/projects/current/{name}/summary.md`): the human↔agent release/status/comms layer between `~/.agent` runtime and the in-repo CHANGELOG. Mirrors git + `~/.agent` into the `## ← Release & status feed` AUTO block (deterministic; `/lab-sync` + weekly `agentctl@lab-sync`); your `## → For the agents` comments are injected at turn 1 by the preflight. Triggers: manual, weekly, on-release (release/bug-bash skills), on `/wind-down`
- `wind-down` — end-of-session self-teardown: write a wrap-up note to `~/.agent/sessions/{project}/<date>-wind-down.md` (runtime axis, not the vault), then arm a deferred `tmux kill-window` (or `--session`) that fires from `stop-post.d/95-wind-down.sh` after the Stop pipeline + eval run; gated on Stop checks (defers the kill if they fail). Trigger: "wind down" / "spin yourself down" / `/wind-down`

**Jira / tickets**
- `jira-ticket-pipeline` — CREATE new tickets in the Feature → Story → Sub-task pipeline shape (Story + technical Sub-tasks under a Feature, with body templates + branch slugs); reads the project's `workflow.md` / `CLAUDE.local.md`
- `jira-subtask-conform` — reshape EXISTING tickets to that shape; optionally label sub-tasks In Development vs Blocked

**Research**
- `deep-research` — multi-agent web research (broad/contested questions) with an adversarial verify pass
- `deep-research-code` — multi-agent investigation of YOUR OWN systems (code + live infra/tools + web) with a live-verify pass; use for "what'll it take to get X to prod", "why does Y keep failing", "is Z actually fixed", pipeline audits

**Workstreams**
- `captain` — **the single front door for all delivery workstreams.** Routes by intent: release asks → release-coordinator; "run a sprint / audit everything" → the sprint loop (kb-sprint-owner queue → one human approval gate → kb-coordinator or verification agents per ticket → CI monitor + merge → tracker Done); "how's it going" → sprint-overseer watch; bug hunts / UI sweeps / prod smoke → those skills. Recurring pings: `/loop 10m /captain watch`. Internal machinery the captain drives (don't invoke directly): `/kb:sprint`, `sprint-overseer`, `kb-sprint-owner`; blackboards at `~/.agent/plans/{project}/sprint-{date}.md`
- `release-coordinator` — release-domain specialist (verbs: status/plan/preflight/monitor/retro); risk-lanes batches, drafts go/no-go briefs, watches the bake window; analysis-only — NEVER satisfies human approval gates or pushes tags; `preflight` checks readiness then hands off to user-invoked `placemyparents-release`. Entry normally via `/captain`; direct access fine
- `bug-bash`, `bug-bash-wrapup` — per-feature bug hunt + e2e/changelog wrap-up
- `ui-audit` — coverage-guaranteed UI/UX audit (inventory → matrix → wave walkthrough → findings → triage); artifacts at `~/.agent/evals/{project}/ui-audit-{date}/`; hands off to `bug-bash`
- `prod-smoke-suite` — `db.sh prod smoke` suite-based regression smoke for placemyparents (10 suites, tRPC + REST); run after every release
- `placemyparents-release` — production release runbook for placemyparents
- `bnb-quality-gates` — what is/isn't enforced in the BNB platform monorepo
- `vikunja-subtask-conform` — conform/restructure a Vikunja project's epic→story→subtask tree to the documented ticket template (BNB ticketing at vikunja.kblab.me, via the `vikunja` MCP)
- `jira-subtask-conform` — same, for Jira epics via the Atlassian MCP (client projects)

**Monitoring**
- `sentinel` — Sentinel 🛰️, the always-on, observe-only monitoring companion. "Keep an eye on X / alert me if X" → a declarative watch at `~/.agent/watches/*.yaml`, polled by a persistent agentctl service (`agentctl@sentinel`, survives logout) that notifies via `agent-notify` ONLY on a state change. Verbs: `watch | list | status | stop | pause | resume`. Deterministic probes (http/metric/kubectl/command) cost zero tokens; the model fires only to diagnose a trip or for a fuzzy `probe: agent` watch (per-hour budget-capped). Observe-only — never executes/mutates/touches release gates. Other agents register watches by dropping a manifest. Runbook: `~/.dotfiles/.config/agentctl/SENTINEL.md`

**Authoring / config**
- `provision-capture` — fold a hand-wired feature (peripheral/service/package/PAM edit) into the dotfiles provisioning system: an idempotent `setup_<feature>()` in the OS installer (`installation_scripts/linux/install_arch.sh`) + a `.config/<feature>/README.md` runbook, following the `setup_printing`/`cups` convention. Use after setting something up manually so a fresh-machine install reproduces it
- `one-pager` — Problem Brief / One-pager / Pitch in `~/.notes/lab/briefs/`
- `update-rules` — manage AI rules across rulesync overview / project CLAUDE.md / AGENTS.md / user-global, with sync (Claude / Codex / Gemini / OpenCode)
- `marp-slide` — Marp presentation decks with themes

If a skill doesn't yet exist for a domain you touch repeatedly, propose one rather than inlining the procedure here. The canonical skills index is `ls ~/.dotfiles/.claude/skills/`; keep this list in sync with that directory (the `update-rules` skill can do the diff for you).

## Agent Delegation

The system's **named identities** (Cap, Sloane, Argus, Mercer, Sentinel, Vera, Mnemosyne, Scribe,
Chronos, and the context-selves) are indexed in `~/.dotfiles/.claude/PERSONAS.md` — the persona
registry (schema, autonomy ladder, naming theme, roster → source files). Add/rename/retire a
persona there; keep each persona's inline `## Persona` block as the per-agent detail.

Non-trivial implementation flows through the `kb-*` agent pipeline:

1. `kb-product-owner` — turns ambiguous asks into Product Briefs
2. `kb-architect` — turns briefs into technical specs / conducts audits. Spec MUST open with a `## Goal` section (one-sentence outcome).
3. *Plan-check (inline, not an agent)* — re-read brief and spec's `## Goal`; on gap, loop back to architect once before coding.
4. `kb-developer` — implements from specs with tests and docs
5. `kb-reviewer` — adversarial code review for bugs/security/correctness; severity-classified findings (BLOCK / FLAG / NIT). Any BLOCK loops back to developer.
6. `kb-qa` — verifies quality gates before merge: goal achieved + lint/typecheck/tests/security/docs. Tests-green-but-goal-missed is a BLOCK.

Entry skills: `/kb:workflow` (full pipeline) and `/kb:implement` (feature → PR). For parallel code exploration, delegate to `Explore` agents. For headless / CI runs (no human in the loop), invoke the `kb-coordinator` agent — it drives the same pipeline end-to-end and returns a structured JSON result.

Above the pipeline sits the sprint loop, entered via **`/captain` — the single conversational front door for all delivery workstreams**: the `kb-sprint-owner` agent (Sloane) builds a prioritized ticket queue, the `/kb:sprint` procedures dispatch `kb-coordinator` per ticket (sequential v1) through merged PR + ticket Done, and the `sprint-overseer` agent (Argus) observes the run as the single notification voice — it never executes. New workstreams plug into the captain's routing table rather than adding user-facing front doors. release-coordinator stays decoupled: it supplies release-impact input to the queue, and merged batches surface in its `status` automatically.

Adjacent to the pipeline: the `release-coordinator` agent (routed via `/captain`; direct `/release-coordinator` also fine) is the **analysis-only release persona** — delegate release-state dashboards, risk-lane batch classification, preflight readiness verdicts, and bake-window monitoring analysis to it. It consumes kb-qa-passed merged work and NEVER executes deploys, pushes tags, or satisfies the human approval gates; execution is always the user invoking `placemyparents-release`.

Also adjacent: the `compliance-counsel` agent (Vera ⚖️) is the **advisory regulatory-counsel persona** — delegate anything touching regulated/sensitive data (PHI/HIPAA, PII, GDPR, FTC/state health-privacy, SOC2, vendor BAAs/DPAs, covered-product coverage, data-residency) and "are we compliant?" / "is `<vendor>` HIPAA-covered for `<product>`?" questions. It **verifies claims against the vendor's live docs / the primary regulation instead of from memory** (cites + dates the source), separates technical truth from a lawyer's ruling, determines regulatory scope first, and names the human-counsel / BAA gate. Analysis-only — like release-coordinator it NEVER satisfies a legal/approval gate and never poses as the lawyer. Pairs with the `compliance` skill (the dated reference lookup: scope decision tree + covered-product matrix + verify-don't-recall method).

Standing beside the pipeline is the **`sentinel` skill (Sentinel 🛰️)** — the third observe-only persona after Argus (sprint-overseer) and Mercer (release-coordinator). It is an always-on `agentctl` service that watches a registry of declarative manifests (`~/.agent/watches/*.yaml`) and is the single notification voice for anything it watches — pinging via `agent-notify` only on a state change, and recommending (never executing) on a trip. Delegate "keep an eye on X / alert me if X" asks to it. Other agents register watches by dropping a manifest with an `expiry`; release-coordinator's `monitor` verb drops a 60-min bake-window watch so deploys are watched without the user holding a `/loop`. Deterministic-first by design: probes are free; the model fires only to diagnose a trip or judge a fuzzy `probe: agent` watch, budget-capped per hour.

The kb **Phase-0 ticket step is tracker-agnostic and MCP-first**: the active system (verbs `system|resolve-epic|claim|create|done|pr-line`) is chosen per-repo from `project-map.json` `trackers` (vikunja/jira/clickup/linear/notion/local) — vikunja=home/personal default, clickup="gigantic playground", jira=Deloitte. Two write modes: **drive the system's MCP** per `docs/adapters/<system>.md` when it's connected, else the `ticket` CLI (on PATH; token+curl) as the headless/CI fallback. Never hard-code a ticketing system. Vikunja emits the legacy `Vikunja: <id>` PR line (both modes) for CI compatibility; others emit `Ticket: <System> <id>`. Contract + adapters + how to add one: `~/.dotfiles/.local/src/ticket/docs/contract.md`.

**Canonical entry policy:** `/kb:*` is the canonical entry point for non-trivial implementation. The retained `/sc:*` commands are quick standalone utilities, not pipeline entries — do not use them as substitutes for `/kb:workflow` or `/kb:implement`.

## Project Mapping

Canonical project names come from `~/.dotfiles/.config/shared-hooks/project-map.json`. The SessionStart and Stop hooks resolve `$CLAUDE_PROJECT_DIR` through that map; edit the JSON file to add or rename a mapping rather than renaming `~/.agent/plans/` dirs by hand.

Resolution order: exact-path → basename-alias → basename (leading dot stripped). So `/home/kblack0610/.dotfiles` → `dotfiles`, not `.dotfiles`.

## Compact Handoff

Preserve the modified files, verification results, key architectural decisions, task status, next step, active plan location when one exists, and recurring error patterns with their fixes.

## Session Eval Format

The Stop hook (`stop-post.d/90-eval-gate.sh`) blocks once per turn with a terse JSON block:

```
eval=<path>[ ci=PASS|FAIL]
lessons=<path>
[sections=±X,±Y]
Stopped: <ts>
```

Append a session entry to `<eval-path>`:
- Header: `## Session N (label)` — same-day session counter; `label` is a short action summary.
- One bullet per section, format: `- **Section**: N/10 — brief note`.
- Close with: `**Summary:** … Overall: N/10.`
- Capture user corrections this turn in `<lessons-path>`.

**Default sections** (when no `sections=` line is present): Workflow, Verification, Code Hygiene, Scope Alignment, Compact Handoff, Lessons. The `sections=±X,±Y` line, when present, applies deltas (`+Infrastructure` adds, `-Lessons` removes).

**Stopped cookie**: copy the `Stopped: <ts>` line verbatim at the end of your summary — it proves you read the block. No "End your response with..." instruction is included in the block; this rule is the instruction.
