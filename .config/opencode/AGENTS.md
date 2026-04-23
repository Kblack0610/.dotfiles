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

If a skill doesn't yet exist for a domain you touch repeatedly, propose one rather than inlining the procedure here.

## Agent Delegation

Non-trivial implementation work flows through the G2I (Ghee-to-Implementation) agents:

1. `kb-product-owner` — turns ambiguous asks into Product Briefs
2. `kb-architect` — turns briefs into technical specs / conducts audits
3. `kb-developer` — implements from specs with tests and docs
4. `kb-qa` — verifies quality gates before merge

For isolated Linear tickets, use `kb-linear-implementer` (fetch ticket → implement → PR, isolated context).

Entry-point skills: `/kb:workflow` (full flow), `/kb:ticket` (Linear-driven), `/kb:implement` (feature → PR).

For parallel code exploration or independent research queries, delegate to `Explore` agents.

## Project Mapping

- `gheegle`, `ghee-sheets`, `ghee-*` -> `~/.agent/plans/gheegle/`
- `shack`, `search` -> `~/.agent/plans/shack/`
- `dotfiles`, `waybar`, `zellij` -> `~/.agent/plans/dotfiles/`
- `binks-agent`, `orchestrator` -> `~/.agent/plans/binks-agent/`
- `bnb-platform`, `monorepo` -> `~/.agent/plans/bnb-platform/`

## Compact Handoff

Preserve the modified files, verification results, key architectural decisions, task status, next step, active plan location when one exists, and recurring error patterns with their fixes.
