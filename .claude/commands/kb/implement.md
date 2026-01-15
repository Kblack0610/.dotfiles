---
name: implement
description: Implement a feature and create a PR
argument-hint: [description]
allowed-tools: Bash, Read, Write, Edit, Grep, Glob
---

# Implement: $ARGUMENTS

## Workflow

1. **Understand requirements** from the description
2. **Check existing code** for patterns and conventions
3. **Implement** following project conventions (check CLAUDE.md if exists)
4. **CI checks run automatically** via Stop hook when finished
5. **Create PR** with `gh pr create`
6. **Report** PR URL and summary

## PR Format

```bash
gh pr create \
  --title "feat: $ARGUMENTS" \
  --body "$(cat <<'EOF'
## Summary
$ARGUMENTS

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
