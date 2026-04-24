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

    After ANY correction from the user: update 'tasks/lessons.md' with the pattern
    Write rules for yourself that prevent the same mistake
    Ruthlessly iterate on these lessons until mistake rate drops
    Review lessons at session start for relevant project

4. Verification Before Done

    Never mark a task complete without proving it works
    Diff behavior between main and your changes when relevant
    Ask yourself: "Would a staff engineer approve this?"
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

    Plan First: Write plan to '~/.agent/plans/{project}/' with checkable items
    Verify Plan: Check in before starting implementation
    Track Progress: Mark items complete as you go
    Explain Changes: High-level summary at each step
    Document Results: Add review to '~/.agent/plans/{project}/'
    Capture Lessons: Update '~/.agent/lessons/{project}.md' after corrections

Core Principles

    Simplicity First: Make every change as simple as possible. Impact minimal code.
    No Laziness: Find root causes. No temporary fixes. Senior developer standards.
    Minimal Impact: Changes should only touch what's necessary. Avoid introducing bugs.

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

## Verification

- Do not mark work complete without verification that matches the change.
- Run the smallest credible validation that proves the change.
- Report what was verified and what could not be verified.

## Infrastructure Questions

- For infrastructure, cluster, deployment, ingress, or Kubernetes status questions, identify the target environment explicitly before answering.
- Do not assume a default production cluster when multiple clusters may exist.
- Prefer repo-local infrastructure docs and manifests for project-specific operational truth, then verify against the live target context when access is available.
- If a repo distinguishes between a navigation hub and domain docs, treat the domain docs as the source of truth for operational details.

## Prefer skills over raw tooling and MCPs

When a skill exists for an operational domain, use it instead of hand-rolling commands or reaching for the equivalent MCP. The skill encodes the current environments, conventions, and safety checks:

If a skill doesn't yet exist for a domain you touch repeatedly, propose one rather than inlining the procedure here.

## Agent Delegation

Non-trivial implementation work flows for agents:

1. `kb-product-owner` — turns ambiguous asks into Product Briefs
2. `kb-architect` — turns briefs into technical specs / conducts audits
3. `kb-developer` — implements from specs with tests and docs
4. `kb-qa` — verifies quality gates before merge

For isolated Linear tickets, use `kb-linear-implementer` (fetch ticket → implement → PR, isolated context).

Entry-point skills: `/kb:workflow` (full flow), `/kb:ticket` (Linear-driven), `/kb:implement` (feature → PR).

For parallel code exploration or independent research queries, delegate to `Explore` agents.

## Compact Handoff

Preserve the modified files, verification results, key architectural decisions, task status, next step, active plan location when one exists, and recurring error patterns with their fixes.


