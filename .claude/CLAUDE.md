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
| Skill knowledge | `~/.claude/skills/` | Auto-loaded when skill is invoked |

When writing memories, prefer mem0 (via the `mem0-ops` skill) for facts that should ride across projects/tools and lessons for project-specific corrections. Don't write project runbooks to memory — those belong in the project repo.

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
- `adb-ops` — Android debug bridge / emulator / APK install / logcat

**Notes / memory**
- `notes-system` — `~/.notes` journal (do not hand-write entries into `~/.notes/journal/`)
- `mem0-ops` — cross-project, cross-tool long-term memory at `mem0.kblab.me`
- `project-index` — refresh a project's anchor (`~/.agent/anchors/{project}.md`), the per-project memory/index.md front door the SessionStart hook injects at turn 1

**Research**
- `deep-research` — multi-agent web research (broad/contested questions) with an adversarial verify pass
- `deep-research-code` — multi-agent investigation of YOUR OWN systems (code + live infra/tools + web) with a live-verify pass; use for "what'll it take to get X to prod", "why does Y keep failing", "is Z actually fixed", pipeline audits

**Workstreams**
- `bug-bash`, `bug-bash-wrapup` — per-feature bug hunt + e2e/changelog wrap-up
- `ui-audit` — coverage-guaranteed UI/UX audit (inventory → matrix → wave walkthrough → findings → triage); artifacts at `~/.agent/evals/{project}/ui-audit-{date}/`; hands off to `bug-bash`
- `prod-smoke-suite` — `db.sh prod smoke` suite-based regression smoke for placemyparents (10 suites, tRPC + REST); run after every release
- `placemyparents-release` — production release runbook for placemyparents
- `bnb-quality-gates` — what is/isn't enforced in the BNB platform monorepo
- `vikunja-subtask-conform` — conform/restructure a Vikunja project's epic→story→subtask tree to the documented ticket template (BNB ticketing at vikunja.kblab.me, via the `vikunja` MCP)
- `jira-subtask-conform` — same, for Jira epics via the Atlassian MCP (client projects)

**Authoring / config**
- `one-pager` — Problem Brief / One-pager / Pitch in `~/.notes/lab/briefs/`
- `update-rules` — manage AI rules across rulesync overview / project CLAUDE.md / AGENTS.md / user-global, with sync (Claude / Codex / Gemini / OpenCode)
- `marp-slide` — Marp presentation decks with themes

If a skill doesn't yet exist for a domain you touch repeatedly, propose one rather than inlining the procedure here. The canonical skills index is `ls ~/.dotfiles/.claude/skills/`; keep this list in sync with that directory (the `update-rules` skill can do the diff for you).

## Agent Delegation

Non-trivial implementation flows through the `kb-*` agent pipeline:

1. `kb-product-owner` — turns ambiguous asks into Product Briefs
2. `kb-architect` — turns briefs into technical specs / conducts audits. Spec MUST open with a `## Goal` section (one-sentence outcome).
3. *Plan-check (inline, not an agent)* — re-read brief and spec's `## Goal`; on gap, loop back to architect once before coding.
4. `kb-developer` — implements from specs with tests and docs
5. `kb-reviewer` — adversarial code review for bugs/security/correctness; severity-classified findings (BLOCK / FLAG / NIT). Any BLOCK loops back to developer.
6. `kb-qa` — verifies quality gates before merge: goal achieved + lint/typecheck/tests/security/docs. Tests-green-but-goal-missed is a BLOCK.

Entry skills: `/kb:workflow` (full pipeline) and `/kb:implement` (feature → PR). For parallel code exploration, delegate to `Explore` agents. For headless / CI runs (no human in the loop), invoke the `kb-coordinator` agent — it drives the same pipeline end-to-end and returns a structured JSON result.

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
