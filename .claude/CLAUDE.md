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

## Operating Model

- Keep reusable shared rules and MCP definitions in `~/.dotfiles/.config/rulesync-global/`.
- Keep machine-local runtime state in tool-specific home directories such as `~/.codex`, `~/.claude`, `~/.gemini`, and `~/.config/opencode`.

## Memory Routing

| Knowledge type | Where it lives | How it gets recalled |
|---|---|---|
| User prefs (tooling choices, repo paths, workflow style) | self-hosted mem0 at `mem0.kblab.me` (`user_id=kblack0610`) | `mem0-ops` skill — curl `/search?query=...&user_id=kblack0610` early in any session that touches user prefs |
| Cross-project facts ("project A uses X", client conventions) | self-hosted mem0 (`user_id=kblack0610`, optional `agent_id=<project>`) | Same — `mem0-ops` skill |
| Project-specific corrections / lessons | `~/.agent/lessons/{project}.md` | SessionStart hook injects last-20 automatically; no tool call needed |
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

- `notes-system` — `~/.notes` journal (do not hand-write entries into `~/.notes/journal/`)
- `k8s-ops` — Kubernetes (home-k3s, do-nyc3-placemyparents-k8s-prod, k3d-local)
- `cloudflare-ops` — DNS/tunnels for kennethblack.me, blacknbrownstudios.com, binks.chat, kblack.dev
- `forgejo-ops` — git.kblab.me on home-k3s
- `gh-workflows` — GitHub PRs, issues, CI, releases (preferred over any GitHub MCP)

If a skill doesn't yet exist for a domain you touch repeatedly, propose one rather than inlining the procedure here.

## Agent Delegation

Non-trivial implementation flows through the G2I (Ghee-to-Implementation) pipeline:

1. `kb-product-owner` — turns ambiguous asks into Product Briefs
2. `kb-architect` — turns briefs into technical specs / conducts audits
3. `kb-developer` — implements from specs with tests and docs
4. `kb-qa` — verifies quality gates before merge

For isolated Linear tickets: `kb-linear-implementer` (fetch → implement → PR, isolated context). Entry skills: `/kb:workflow` (full), `/kb:ticket` (Linear-driven), `/kb:implement` (feature → PR). For parallel code exploration, delegate to `Explore` agents.

## Project Mapping

- `dotfiles`, `waybar`, `zellij` → `~/.agent/plans/dotfiles/`
- `binks-agent`, `orchestrator` → `~/.agent/plans/binks-agent/`
- `bnb-platform`, `monorepo` → `~/.agent/plans/bnb-platform/`

## Compact Handoff

Preserve the modified files, verification results, key architectural decisions, task status, next step, active plan location when one exists, and recurring error patterns with their fixes.

## Session Eval Format

When the Stop hook blocks with "Session eval for {project}", append to the named eval file:
- Header: `## Session N (label)` — same-day session counter; `label` is a short action summary.
- One bullet per section listed in the hook's "Score sections" line, format: `- **Section**: N/10 — brief note`.
- Close with: `**Summary:** … Overall: N/10.`
- Capture any user corrections this turn in the named lessons file.
