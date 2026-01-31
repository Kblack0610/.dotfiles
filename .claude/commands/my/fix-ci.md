---
name: fix-ci
description: "Fix all CI errors: lint, e2e, integration tests, and status checks"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch, WebSearch, TodoWrite, AskUserQuestion, mcp__github-gh__gh_pr_checks, mcp__github-gh__gh_run_list, mcp__github-gh__gh_run_view, mcp__github-gh__gh_pr_view, mcp__github-gh__gh_pr_list]
---

Please fix all errors with lint, end-to-end testing, integration testing, and any other status check. Make sure to monitor CI and test locally to continually fix these issues until they are completely fixed, and CI is green.

## Workflow

1. **Identify the current branch and PR** - Check git status and find the associated PR
2. **Check CI status** - Look at GitHub Actions runs and PR checks to identify failures
3. **Run local checks first** - Run lint, typecheck, tests locally to reproduce issues
4. **Fix issues iteratively** - For each failing check:
   - Understand the error
   - Fix the root cause
   - Verify the fix locally
   - Commit the fix
5. **Push and monitor** - Push fixes and monitor CI until all checks pass
6. **Repeat** - If new failures appear, go back to step 2

## Local Commands to Try

- `pnpm lint` - Run linting
- `pnpm typecheck` or `pnpm tsc --noEmit` - Type checking
- `pnpm test` - Unit/integration tests
- `pnpm e2e` or `pnpm test:e2e` - End-to-end tests
- `pnpm build` - Build check

## Important

- Always check package.json scripts to find the correct commands
- Fix the root cause, not symptoms
- Commit fixes with clear messages describing what was fixed
- Monitor CI after pushing to catch any remaining issues
- Don't stop until ALL checks are green
