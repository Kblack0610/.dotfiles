---
name: ticket
description: Implement a Linear ticket with CI checks and PR creation
argument-hint: [ticket-id]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Implement Linear Ticket: $ARGUMENTS

## Workflow

1. **Fetch ticket** using `mcp__linear__get_issue` with id `$ARGUMENTS`
2. **Review requirements** - title, description, acceptance criteria
3. **Check existing code** for patterns and conventions
4. **Implement** following project conventions (check CLAUDE.md if exists)
5. **CI checks run automatically** via Stop hook when finished
6. **Create PR** with `gh pr create` linking to ticket
7. **Report** PR URL and summary

## PR Format

```bash
gh pr create \
  --title "feat(scope): description ($ARGUMENTS)" \
  --body "$(cat <<'EOF'
## Summary
- Implementation details

## Linear Ticket
https://linear.app/team/issue/$ARGUMENTS

## Test Plan
- Verification steps
EOF
)"
```

## Commit Format

Use conventional commits with ticket reference:
```
feat(scope): description ($ARGUMENTS)
fix(scope): description ($ARGUMENTS)
```

## Rules

- Never create PR if CI fails (Stop hook enforces this)
- Reference ticket ID in all commit messages
- Link to Linear ticket in PR body
- Follow existing code patterns and conventions
