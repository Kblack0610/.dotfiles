---
name: merge-dev-ci
description: "Merge latest dev, clean conflicts, push to PR and monitor CI till green"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task, mcp__github-gh__gh_pr_checks, mcp__github-gh__gh_pr_view, mcp__github-gh__gh_run_list, mcp__github-gh__gh_run_view]
---

# Merge Dev and Monitor CI

Merge the latest dev branch into the current feature branch, resolve any conflicts, push to the PR, and monitor CI until it passes.

## Steps

### 1. Fetch and merge dev
```bash
git fetch origin dev
git merge origin/dev
```

### 2. Handle conflicts
If there are merge conflicts:
- List conflicted files with `git diff --name-only --diff-filter=U`
- For each conflicted file, read it and resolve conflicts intelligently
- Prefer the feature branch changes where they represent intentional changes
- Keep dev changes where they're unrelated fixes or updates
- After resolving, stage with `git add`

### 3. Complete merge and push
```bash
git commit -m "Merge branch 'dev' into $(git branch --show-current)"
git push
```

### 4. Monitor CI
- Get PR number from current branch
- Poll CI status every 30 seconds using `gh pr checks`
- Report progress: pending checks, passing checks, failing checks
- If a check fails, investigate the logs and report what went wrong
- Continue until all checks pass or a definitive failure occurs

### 5. Report final status
- Summarize what was merged
- Report any conflicts that were resolved
- Confirm CI status (green or explain failures)
