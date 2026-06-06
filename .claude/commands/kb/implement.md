---
name: implement
description: Implement a feature and create a PR
argument-hint: [description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Implement: $ARGUMENTS

## Workflow

1. **Understand requirements** from the description
2. **Vikunja ticket — FIRST ACTION, mechanical** (see below). Run the helper script and capture
   the id into `VIKUNJA_TASK_ID`. Skip cleanly only for repos without a Vikunja wiring or when
   the user explicitly said "no ticket" — every other PR body **must** carry either
   `Vikunja: <id>` or `Vikunja: none` with a one-line reason.
3. **Check existing code** for patterns and conventions
4. **Implement** following project conventions (check CLAUDE.md if exists)
5. **CI checks run automatically** via Stop hook when finished
6. **Create PR** with `gh pr create` — body **must** contain `Vikunja: $VIKUNJA_TASK_ID` (or
   `Vikunja: none` with reason). The `vikunja-pr-gate.yml` workflow rejects bodies missing the line.
7. **Self-check before reporting**: did I record a `VIKUNJA_TASK_ID`? Does the PR body carry it?
   If no id was captured, the body MUST say `Vikunja: none` AND explain why in that same line.
8. **Report** PR URL and Vikunja task id.

## Vikunja ticket step (mechanical)

Repos with `scripts/vikunja-pr.sh` (currently: `bnb/platform`) expose a helper that does all the
GET→modify→POST + label + bucket-move work in one call. Use it instead of hand-walking the API.

```bash
# If the user supplied a task id (most common — they pasted one or there's an obvious open ticket):
VIKUNJA_TASK_ID=$(./scripts/vikunja-pr.sh claim 196)

# Otherwise, create a fresh one. Resolve the epic shorthand first if you don't know the pid.
EPIC_PID=$(./scripts/vikunja-pr.sh resolve-epic ci)   # ci | mobile-ci | mobile | backups | compliance | preview | release
VIKUNJA_TASK_ID=$(./scripts/vikunja-pr.sh create "$EPIC_PID" "fix(web): broken signup link" --labels=ci,P2)

echo "VIKUNJA_TASK_ID=$VIKUNJA_TASK_ID"   # capture for the PR body
```

The helper auto-applies `In Development`, removes `Todo`, and moves the card to the epic's `Doing`
bucket. Label names accepted: `In Development`, `web`, `api`, `mobile`, `infra`, `ci`, `security`,
`compliance`, `P0`–`P3` (with optional `area:`/`priority:` prefixes). Both env vars
`VIKUNJA_API_TOKEN` and `VIKUNJA_MCP_TOKEN` work.

**Fallback when the helper isn't present** (other repos, fresh worktree, etc.): use the `vikunja`
MCP directly — `vikunja_projects subcommand:"get-tree"` (parent ids 3 and 9) to find the epic,
`vikunja_tasks subcommand:"create"` to create, `vikunja_tasks subcommand:"apply-label"` with
`labels:[1,9,14]` for In Development + ci + P2 (label ids: state In Development=1 Todo=16 Done=3;
area web=5 api=6 mobile=7 infra=8 ci=9 security=10 compliance=11; priority P0=12 P1=13 P2=14 P3=15),
and a raw curl for the bucket move:

```bash
curl -s -X POST -H "Authorization: Bearer $VIKUNJA_MCP_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"task_id": <TASK_ID>}' \
  "https://vikunja.kblab.me/api/v1/projects/<PROJECT_ID>/views/<VIEW_ID>/buckets/<DOING_BUCKET_ID>/tasks"
```

## PR Format

```bash
gh pr create \
  --title "feat: $ARGUMENTS" \
  --body "$(cat <<EOF
## Summary
$ARGUMENTS

## Ticket
Vikunja: ${VIKUNJA_TASK_ID:-none}

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
- If you did NOT record a `VIKUNJA_TASK_ID`, the PR body MUST say `Vikunja: none` and you must
  state the reason on the same line (e.g. `Vikunja: none — typo fix`). The `vikunja-pr-gate.yml`
  check posts an inline comment when the line is missing entirely.
