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

## Verification

- Do not mark work complete without verification that matches the change.
- Run the smallest credible validation that proves the change.
- Report what was verified and what could not be verified.

## Project Mapping

- `gheegle`, `ghee-sheets`, `ghee-*` -> `~/.agent/plans/gheegle/`
- `shack`, `search` -> `~/.agent/plans/shack/`
- `dotfiles`, `waybar`, `zellij` -> `~/.agent/plans/dotfiles/`
- `binks-agent`, `orchestrator` -> `~/.agent/plans/binks-agent/`
- `bnb-platform`, `monorepo` -> `~/.agent/plans/bnb-platform/`

## Compact Handoff

Preserve the modified files, verification results, key architectural decisions, task status, next step, active plan location when one exists, and recurring error patterns with their fixes.
