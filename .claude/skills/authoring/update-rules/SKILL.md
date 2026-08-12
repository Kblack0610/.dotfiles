---
name: update-rules
description: Add, edit, or remove AI assistant rules across the right layer (rulesync overview / project CLAUDE.md / AGENTS.md / project-repo rules) and run the sync so Claude, Codex, Gemini, and OpenCode all see the change. Use when the user says "add a rule", "from now on always X", "stop doing Y everywhere", "update CLAUDE.md", "update AGENTS.md", "add this to the rules", "register a new skill in CLAUDE.md", or "register a new MCP server". Differs from update-config (settings.json/permissions/hooks).
metadata:
  category: authoring
  tags: [rules, claude-md, sync]
  reviewed: "2026-08-03"
---

# update-rules

Edit the rule layer with the correct scope, then sync. This skill picks the right file to touch and runs the fan-out.

## The one thing that trips everyone up

**The rule CONTENT lives in the PRIVATE overlay. This SKILL lives in the PUBLIC repo.**

`~/.dotfiles-private` holds every rule file - `CLAUDE.md`, `AGENTS.md`, and the whole rulesync tree. `~/.dotfiles` holds this skill and the sync script. If you go looking for a rule file under `~/.dotfiles/`, you will not find it.

There is no `~/.dotfiles/.claude/CLAUDE.md`, no `~/.dotfiles/AGENTS.md`, and no `~/.dotfiles/.config/rulesync-global/`. <!-- skill-drift: ignore (this line asserts these paths are ABSENT) -->

Practical consequence: **a rule change plus a skill change is a cross-repo change = two PRs.** Use `dotfiles-land` to route it.

## Quick decision tree

Ask first: **which tools should obey this rule?**

| Scope | Edit | Affects |
|---|---|---|
| All AI tools (Claude + Codex + Gemini + OpenCode) | `~/.dotfiles-private/.config/rulesync-global/.rulesync/rules/overview.md` + run sync | Everything via rulesync fan-out |
| Claude-only (user-global) | `~/.dotfiles-private/.claude/CLAUDE.md` | Claude Code (symlinked to `~/.claude/CLAUDE.md`) |
| Codex-only (repo root) | `~/.dotfiles-private/AGENTS.md` | Codex CLI (auto-loaded from repo root) |
| One project | `<project>/CLAUDE.md` or `<project>/.claude/CLAUDE.md` and/or `<project>/AGENTS.md` | Only that repo |
| MCP server (cross-tool) | `~/.dotfiles-private/.config/rulesync-global/.rulesync/mcp.json` + run sync | Claude / Codex / Gemini / OpenCode MCP configs |

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
- Does NOT write: `~/.claude/CLAUDE.md` or `~/.claude/.mcp.json` - those are symlinks into `~/.dotfiles-private/.claude/`. Editing the private file IS the deploy; no sync needed.

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
4. If the rule is also worth pinning in the Claude-flavored `CLAUDE.md` (richer prose, eval format, memory routing), mirror it there. The Claude file is intentionally a superset, not a copy.
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

1. Edit `~/.dotfiles-private/.config/rulesync-global/.rulesync/mcp.json` (top-level `mcpServers` map).
2. Run the sync. The script merges the entries into each tool's native MCP config.
3. Restart any tool already running (Claude Code, Codex) to pick up the new server.

### Register a new skill in the CLAUDE.md skills list

The "Prefer skills over raw tooling and MCPs" section in `~/.dotfiles-private/.claude/CLAUDE.md` should mirror the skills on disk. **The canonical index is `~/.claude/skills/`** - the union of both repos (public skills and private skills are both symlinked in there). Listing only `~/.dotfiles/.claude/skills/` misses every private skill.

Show the drift:

```bash
skill-drift
```

`UNLISTED` = on disk, missing from CLAUDE.md (add a bullet). `GHOST` = bulleted but not on disk (retired - remove the bullet). `UNDEPLOYED` = in a repo but not symlinked into `~/.claude/skills/`, so it is documented and unreachable.

Add a one-line bullet under the right category (Infra/ops, Notes/memory, Jira/tickets, Research, Workstreams, Monitoring, Authoring/config) in the same style as its neighbors.

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
# Shared overview vs the Claude-flavored superset
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
- Don't duplicate across layers. If a rule lives in the shared overview, it doesn't also need to be in the Claude superset unless the Claude-side context (eval format, memory routing) materially changes how to apply it.
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
- **Skills-list edits:** `skill-drift` reports no new `UNLISTED` or `GHOST`.
- **Landing:** rule content is private, this skill is public. `dotfiles-land` splits a cross-repo change into two PRs.
