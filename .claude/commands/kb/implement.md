---
name: implement
description: Implement a feature and create a PR
argument-hint: [description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Implement: $ARGUMENTS

## Workflow

1. **Understand requirements** from the description
2. **Claim or create a Vikunja ticket** (see below) — only when the repo has a Vikunja board
   wired (currently: `bnb/platform`). Skip cleanly for trivial PRs the user explicitly tagged
   as "no ticket" or for repos without the ticketing convention.
3. **Check existing code** for patterns and conventions
4. **Implement** following project conventions (check CLAUDE.md if exists)
5. **CI checks run automatically** via Stop hook when finished
6. **Create PR** with `gh pr create` — include the `Vikunja: <id>` line in the body
7. **Report** PR URL and Vikunja task id

## Vikunja ticket step (bnb/platform only)

The platform CLAUDE.md `Ticketing (Vikunja)` block is the source of truth for the flow.

- If the user already supplied a task id: fetch it via `vikunja_tasks` MCP (`subcommand: "get"`),
  apply the `In Development` label (id 1), remove `Todo` (id 16) if present, and move the card to
  the epic's `Doing` bucket.
- Otherwise: ask which epic this work belongs to (list epic projects via `vikunja_projects`
  `subcommand: "get-tree"`, parent ids 3 and 9). Create a task via `vikunja_tasks`
  `subcommand: "create"`, title derived from the user's request, apply labels for state
  (`In Development` = 1) + area (`web` 5, `api` 6, `mobile` 7, `infra` 8, `ci` 9, `security` 10,
  `compliance` 11) + priority (`P0` 12, `P1` 13, `P2` 14, `P3` 15). Move it to the `Doing` bucket
  via the raw API (the MCP doesn't expose `bucket_id`):

  ```bash
  curl -s -X POST -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
    -H "Content-Type: application/json" \
    -d '{"task_id": <TASK_ID>}' \
    "https://vikunja.kblab.me/api/v1/projects/<PROJECT_ID>/views/<VIEW_ID>/buckets/<DOING_BUCKET_ID>/tasks"
  ```

- Echo the task id back so it lands in the PR body.

## PR Format

```bash
gh pr create \
  --title "feat: $ARGUMENTS" \
  --body "$(cat <<'EOF'
## Summary
$ARGUMENTS

## Ticket
Vikunja: <task-id>   # or "none" for trivial PRs

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
- Always include the `Vikunja:` line in the PR body for repos with the wired board — the
  `vikunja-close-on-merge.yml` action parses it and flips the task to Done on merge.
