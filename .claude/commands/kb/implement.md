---
name: implement
description: Implement a feature and create a PR
argument-hint: [description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Implement: $ARGUMENTS

## Workflow

1. **Understand requirements** from the description
2. **Ticket — FIRST ACTION, mechanical, tracker-agnostic** (see below). Run the `ticket` CLI and
   capture the PR-body line into `TICKET_LINE`. Skip cleanly only for repos with no tracker
   configured or when the user explicitly said "no ticket" — every other PR body **must** carry
   either the captured line or `Ticket: none` with a one-line reason.
3. **Check existing code** for patterns and conventions
4. **Implement** following project conventions (check CLAUDE.md if exists)
5. **CI checks run automatically** via Stop hook when finished
6. **Create PR** with `gh pr create` — body **must** contain `$TICKET_LINE` (or `Ticket: none`
   with reason). For vikunja repos the line is `Vikunja: <id>`; the `vikunja-pr-gate.yml` workflow
   rejects bodies missing it.
7. **Self-check before reporting**: did I capture a non-`none` `TICKET_LINE`? Does the PR body
   carry it? If not, the body MUST say `Ticket: none` AND explain why in that same line.
8. **Report** PR URL and the ticket reference.

## Ticket step (tracker-agnostic, MCP-first)

The active system is chosen per-repo from `project-map.json` `trackers` (vikunja / jira / clickup /
linear / notion / local). Resolve it, then write the ticket one of two ways (full contract +
per-system adapter specs: `~/.dotfiles/.local/src/ticket/docs/contract.md`).

```bash
SYS=$(ticket system 2>/dev/null || echo none)
```

1. **MCP-first:** if the `$SYS` MCP is connected, drive it per `docs/adapters/$SYS.md` (claim the
   supplied id, or resolve-epic + create) and capture the PR-line it specifies. Uses the MCP's auth.
2. **CLI fallback** (headless/CI, no MCP):

```bash
if [ "$SYS" = none ]; then
  TICKET_LINE="Ticket: none — no tracker configured for this repo"
elif [ -n "$USER_TASK_ID" ]; then            # most common: user pasted an id / obvious open ticket
  TICKET_LINE=$(ticket claim "$USER_TASK_ID")
else                                          # create a fresh one; AREA e.g. ci|mobile|release
  TICKET_LINE=$(ticket create "$(ticket resolve-epic "$AREA")" "fix(web): broken signup link" --labels="$AREA,P2")
fi
echo "$TICKET_LINE"   # capture for the PR body — 'Vikunja: 213' or 'Ticket: Jira ABC-9'
```

Both modes mark the ticket In-Dev and move it to Doing, and honor the same abstract labels (state
`in-dev`/`blocked`/`done`/`todo`, area `web`/`api`/`mobile`/`infra`/`ci`/`security`/`compliance`,
priority `P0`–`P3`). Verify CLI wiring without writes via `ticket --dry-run create …`. A repo can
fully own its ticketing by shipping an executable `scripts/ticket.sh`; the CLI defers to it.

## PR Format

```bash
gh pr create \
  --title "feat: $ARGUMENTS" \
  --body "$(cat <<EOF
## Summary
$ARGUMENTS

## Ticket
${TICKET_LINE:-Ticket: none}

## Changes
- List of changes made

## Test Plan
- How to verify the changes
EOF
)"
```

## Rules

- Never create PR if CI fails (Stop hook enforces this)
- Use conventional commits: `feat:`, `fix:`, `refactor:`, etc.
- Follow existing code patterns and conventions
- Keep changes focused and reviewable
- Always include the captured `$TICKET_LINE` in the PR body for repos with a wired board — on
  vikunja it's `Vikunja: <id>`, which the `vikunja-close-on-merge.yml` action parses to flip the
  task to Done on merge.
- If you did NOT capture a ticket, the PR body MUST say `Ticket: none` and you must state the
  reason on the same line (e.g. `Ticket: none — typo fix`). For vikunja repos the
  `vikunja-pr-gate.yml` check posts an inline comment when the `Vikunja:` line is missing entirely.
