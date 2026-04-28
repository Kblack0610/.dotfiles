# Codex Workflow

This repository is the source of truth for shared Codex behavior. Keep machine-local Codex runtime state in `~/.codex`, but manage reusable instructions, skills, and sync scripts from this repo.

Canonical Codex assets live under `.config/codex/`. Shared cross-agent Rulesync sources live under `.config/rulesync-global/`. This root `AGENTS.md` stays here because Codex discovers project instructions from the repo root.

## Core rules

- Plan before implementation for non-trivial work.
- Re-check existing plans in `~/.agent/plans/{project}/` before starting implementation.
- Do not mark work complete without verification that matches the change.
- Prefer elegant fixes over additive hacks, but do not over-engineer simple changes.
- After a user correction, capture the lesson in `~/.agent/lessons/{project}.md`.

## Plan workflow

- Draft plans live in `~/.agent/plans/{project}/planning/`.
- Approved in-progress plans live in `~/.agent/plans/{project}/active/`.
- Approved but not started plans live in `~/.agent/plans/{project}/backlog/`.
- Completed plans live in `~/.agent/plans/{project}/archive/YYYY-MM/`.
- Use filenames like `YYYY-MM-DD_project_feature-description.md`.

Project mapping:
- `gheegle`, `ghee-sheets`, `ghee-*` -> `~/.agent/plans/gheegle/`
- `shack`, `search` -> `~/.agent/plans/shack/`
- `dotfiles`, `waybar`, `zellij` -> `~/.agent/plans/dotfiles/`
- `binks-agent`, `orchestrator` -> `~/.agent/plans/binks-agent/`
- `bnb-platform`, `monorepo` -> `~/.agent/plans/bnb-platform/`

## Verification

- Run the smallest credible validation that proves the change.
- For repo-level verification heuristics, use `.config/codex/run-project-checks.sh` when appropriate.
- Report what was verified and what could not be verified.

## Skills and delegation

- Use repo-managed Codex skills synced from `.config/codex/skills/`.
- Prefer skills for specialized workflows instead of embedding long reusable instructions in chat.
- Delegate to the `binks-agent` skill when a task fits your local orchestration stack.

## Memory layer

Self-hosted mem0 at `https://mem0.kblab.me` (LAN-only) is the cross-project memory layer for user preferences and cross-project facts. Search it early in any session that touches user prefs ("remember", "prefers", "always", "what did I tell you about"); add to it when learning something new that should ride across projects/tools.

REST endpoints (no auth currently — middleware restricts to RFC1918 + Tailscale):

```bash
# Search before answering — finds the user-pref or cross-project fact
curl -fsS "https://mem0.kblab.me/memories?user_id=kblack0610&query=<question>"

# Add a new memory
curl -fsS -X POST https://mem0.kblab.me/memories -H 'Content-Type: application/json' -d '{
  "messages": [{"role":"user","content":"<fact statement>"}],
  "user_id": "kblack0610"
}'
```

For the full operations table (project-scoped memories with `agent_id`, update, delete, etc.), see the upstream skill's API patterns at <https://github.com/mem0ai/mem0/tree/main/skills/mem0> or the Claude Code-specific scoped skill at `~/.claude/skills/mem0-ops/SKILL.md`.

Don't write file-pointer "trigger" memories ("the X runbook lives at Y/<topic>.md") — mem0's LLM extractor filters them out as not-memory-shaped. Discovery of project runbooks goes via `ls docs/runbooks/` + `grep` in the consuming repo.

## MCP and local setup

- Shared AI rules and MCP server definitions are managed from `.config/rulesync-global/`.
- Sync global Codex, Claude, Gemini, and OpenCode state with `.config/codex/sync-ai-global-config.sh`.
- `.config/codex/sync-codex-config.sh` remains the compatibility entrypoint for Codex users and still syncs Codex skills.
- Do not edit `~/.codex/auth.json`, history, logs, or sqlite state from automation.

## Compact handoff

When summarizing or compacting, preserve:
- modified files and why they changed
- test commands run and their results
- key architectural decisions
- task status and next step
- active plan file location when one exists
- recurring error patterns and fixes
