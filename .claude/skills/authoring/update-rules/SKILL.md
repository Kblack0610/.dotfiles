---
name: update-rules
description: Add, edit, or remove AI assistant rules across the right layer (rulesync overview / project CLAUDE.md / AGENTS.md / project-repo rules) and run the sync so Claude, Codex, Gemini, and OpenCode all see the change. Use when the user says "add a rule", "from now on always X", "stop doing Y everywhere", "update CLAUDE.md", "update AGENTS.md", "add this to the rules", "where should this rule go", or "register a new MCP server". Differs from update-config (settings.json/permissions/hooks).
metadata:
  category: authoring
  tags: [rules, claude-md, sync]
  reviewed: "2026-10-29"
---

# update-rules

Edit the rule layer with the correct scope, then sync. This skill picks the right file to touch and runs the fan-out.

## The one thing that trips everyone up

**The rule CONTENT lives in the PRIVATE overlay. This SKILL lives in the PUBLIC repo.**

`~/.dotfiles-private` holds every rule file - `CLAUDE.md`, `AGENTS.md`, and the whole rulesync tree. `~/.dotfiles` holds this skill and the sync script. If you go looking for a rule file under `~/.dotfiles/`, you will not find it.

There is no `~/.dotfiles/.claude/CLAUDE.md`, no `~/.dotfiles/AGENTS.md`, and no `~/.dotfiles/.config/rulesync-global/`. <!-- skill-drift: ignore (this line asserts these paths are ABSENT) -->

Practical consequence: **a rule change plus a skill change is a cross-repo change = two PRs.** Use `dotfiles-land` to route it.

## Quick decision tree

Ask first: **which repos does this rule apply in, and which tools should obey it?** The placement rule is in the global CLAUDE.md "Standards" section: a rule goes in the global file only when it applies in two or more repos; otherwise in that repo's root CLAUDE.md, a subdirectory CLAUDE.md for one subtree, or the skill when it is a procedure. Never restate a skill there. Budgets: global under 20 KB, a repo root under 12 KB, a `MEMORY.md` under 8 KB. Check `wc -c` before and after.

| Scope | Edit | Affects |
|---|---|---|
| All AI tools (Claude + Codex + Gemini + OpenCode) | `~/.dotfiles-private/.config/rulesync-global/.rulesync/rules/overview.md` + run sync | Everything via rulesync fan-out |
| Claude-only (user-global) | `~/.dotfiles-private/.claude/CLAUDE.md` | Claude Code (symlinked to `~/.claude/CLAUDE.md`) |
| Codex-only (repo root) | `~/.dotfiles-private/AGENTS.md` | Codex CLI (auto-loaded from repo root) |
| One project | `<project>/CLAUDE.md` (or `@AGENTS.md` plus Claude-only lines when the repo has an AGENTS.md) | Only that repo |
| This dotfiles repo | `~/.dotfiles/CLAUDE.md` (public, excluded from stow) | Sessions in `~/.dotfiles` |
| MCP server for Claude | the committed `.mcp.json` of the repo that uses it, or `~/.dotfiles-private/.claude/mcp-optional/<name>.json` for on-demand use (`claude-mcp <name>`) | That repo / sessions that ask for it |
| MCP server for Codex / Gemini / OpenCode | `~/.dotfiles-private/.config/rulesync-global/.rulesync/mcp.json` + run sync | Those tools' MCP configs |

If the user just says "add this rule" without specifying scope, **ask** before editing - the wrong layer creates drift.

## Files and what they own

```
~/.dotfiles-private/                                       # PRIVATE - all rule content
├── AGENTS.md                                              # Codex root (auto-loaded by Codex from repo root)
├── .claude/CLAUDE.md                                      # Claude user-global -> ~/.claude/CLAUDE.md
└── .config/rulesync-global/                               # -> deployed as ~/.config/rulesync-global
    ├── rulesync.jsonc
    └── .rulesync/
        ├── rules/overview.md                              # CANONICAL shared rules
        └── mcp.json                                       # Shared MCP server definitions

~/.dotfiles/                                               # PUBLIC - machinery, no rule content
├── .claude/skills/update-rules/SKILL.md                   # this file
└── .config/codex/sync-ai-global-config.sh                 # the fan-out
```

The sync script reads `$RULESYNC_ROOT` (default `~/.config/rulesync-global`, the stow symlink to the private tree), stages a copy, and runs `rulesync generate`.

What it writes, and what it explicitly does NOT:

- Writes: `~/.codex/AGENTS.md`, `~/.codex/config.toml` (managed block only), `~/.gemini/GEMINI.md`, `~/.gemini/settings.json`, `~/.config/opencode/AGENTS.md`, `~/.config/opencode/opencode.json`
- Does NOT write: `~/.claude/CLAUDE.md` (a symlink into `~/.dotfiles-private/.claude/`; editing the private file IS the deploy) or any Claude MCP config.

## Running the sync

```bash
~/.dotfiles/.config/codex/sync-ai-global-config.sh
```

`rulesync` is **not on PATH**. The script resolves it itself, in order: `$RULESYNC_BIN` -> `command -v rulesync` -> `~/.rulesync/bin/rulesync`. If you invoke rulesync directly (a dry run, say), use the full path or export `RULESYNC_BIN` - a bare `rulesync` will fail with "command not found".

If `~/.config/rulesync-global` is absent (a public-only machine with no private overlay), the script prints a notice and skips rather than failing.

## Workflows

### Add a rule that applies to every AI tool

1. Open `~/.dotfiles-private/.config/rulesync-global/.rulesync/rules/overview.md`.
2. Append to the appropriate section (Operating Model, Workflow Expectations, Verification, Writing Style, Artifact Placement, Infrastructure Questions, Prefer skills, Agent Delegation, Project Mapping, Compact Handoff). Keep it terse - one bullet, with rationale only when non-obvious.
3. Run the sync (above).
4. Claude does not read the overview (the sync skips Claude), so a rule every tool must obey also goes in `~/.dotfiles-private/.claude/CLAUDE.md`, in the same words. Until a sync step generates that block from the overview, the two copies are kept by hand: change both in the same commit.
5. Commit in the **private** repo: `rulesync: add <one-line summary>`.

### Add a Claude-only rule (eval, lessons, plan-mode behavior)

1. Edit `~/.dotfiles-private/.claude/CLAUDE.md`. Live for the next Claude session - no sync (the symlink IS the deploy).
2. If the rule is general enough for the shared layer, prefer the rulesync path above instead.

### Add a Codex-only rule

1. Edit `~/.dotfiles-private/AGENTS.md`. No sync runs against this file - it is the Codex *repo root* file. The sync writes `~/.codex/AGENTS.md`, a **different** copy generated by rulesync from the shared overview.
2. If the rule should reach Codex's home dir, put it in the rulesync overview instead.

### Add a project-specific rule

1. Use `<project>/CLAUDE.md` (Claude) or `<project>/AGENTS.md` (Codex / others). Don't put project-only rules in the dotfiles layer.
2. For project-specific *corrections* (the kind that come from a user redirect), use `~/.agent/lessons/{project}.md` instead - the SessionStart hook auto-injects the last 20.

### Register a new MCP server

1. For Claude: add it to the committed `.mcp.json` of the repo that uses it (`enableAllProjectMcpServers` in settings.json approves it). Never at user scope (`claude mcp add -s user`) and never in a `.mcp.json` above the repos: Claude Code walks up from the cwd, so either one starts the server in every session. A server most sessions do not need goes in `~/.dotfiles-private/.claude/mcp-optional/<name>.json` and loads with `claude-mcp <name>`.
2. For Codex / Gemini / OpenCode: edit `~/.dotfiles-private/.config/rulesync-global/.rulesync/mcp.json` and run the sync. The sync only merges new keys, so a removal also needs a hand edit of `~/.config/opencode/opencode.json`.
3. Restart any tool already running to pick up the change.

### A new skill and CLAUDE.md

Skills are not listed in CLAUDE.md: every skill's description is injected automatically, and that is the index. Add a line to the global "Prefer skills" section only when the new skill collides with an existing one (say which wins) or retires one (add it under "Retired"). `skill-drift` reports `GHOST` for a skill bulleted there that is no longer on disk.

### Remove a rule

1. Locate it - it lives in exactly one of the three files (or a project repo):
   ```bash
   grep -n "<keyword>" ~/.dotfiles-private/.claude/CLAUDE.md \
                       ~/.dotfiles-private/AGENTS.md \
                       ~/.dotfiles-private/.config/rulesync-global/.rulesync/rules/overview.md
   ```
2. Remove the bullet, leave neighboring sections untouched.
3. Run the sync if the file was the rulesync overview or `mcp.json`.

### Audit drift between layers

```bash
# Shared overview vs the Claude file (shared rules must match word for word)
diff -u ~/.dotfiles-private/.config/rulesync-global/.rulesync/rules/overview.md \
        ~/.dotfiles-private/.claude/CLAUDE.md

# Codex root vs the shared overview
diff -u ~/.dotfiles-private/AGENTS.md \
        ~/.dotfiles-private/.config/rulesync-global/.rulesync/rules/overview.md

# Are the generated files stale relative to the source?
~/.dotfiles/.config/codex/sync-ai-global-config.sh
git -C ~/.codex diff --stat; git -C ~/.gemini diff --stat
```

For drift between the rules and *reality* (paths that moved, retired skills still advertised), that is `skill-drift` and the `skill-refine` skill, not this one.

## Style rules for new bullets

- Lead with the imperative or the fact, not throat-clearing.
- Add a `Why:` clause only when the rationale isn't obvious from the rule itself.
- Don't reference today's task / commit / PR - rules outlive incidents.
- Don't duplicate across layers, except the shared-overview copy in the global CLAUDE.md (Claude cannot read the overview).
- Plain ASCII, no hard-wrapping (the house writing style - it is itself one of these rules).

## What this skill does NOT do

- Settings, permissions, hooks, env vars -> `update-config` skill.
- Per-correction lessons -> write directly to `~/.agent/lessons/{project}.md`. The SessionStart hook injects them; no rule-layer change needed.
- User preferences that should ride across projects -> `mem0-ops` skill, not the rule layer.
- Project runbooks -> the project repo's docs, not CLAUDE.md or AGENTS.md.
- Auditing/polishing the skills themselves -> `skill-refine`.

## Verification after a change

- **Shared-layer edits:** the sync script exits 0 and modifies the expected files. Check `git -C ~/.codex diff` and `git -C ~/.gemini diff`.
- **Claude-only edits:** confirm the symlink resolves to the file you edited, so you know the edit is live:
  ```bash
  readlink -f ~/.claude/CLAUDE.md   # -> ~/.dotfiles-private/.claude/CLAUDE.md
  ```
  Then open a new Claude session and check the rule appears in the CLAUDE.md system-reminder block.
- **MCP additions:** list servers in the target tool (`claude mcp list`) and confirm the new one is enumerated.
- **Global CLAUDE.md edits:** `wc -c` is under the budget and `skill-drift` reports no new `GHOST`.
- **Landing:** rule content is private, this skill is public. `dotfiles-land` splits a cross-repo change into two PRs.
