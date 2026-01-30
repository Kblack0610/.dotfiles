---
name: pr-merge-flow
description: "Review PR, fix issues, monitor CI, merge, and continue with next plan task"
allowed-tools: [Bash, Read, Write, Edit, Glob, Grep, Task, WebFetch, WebSearch, TodoWrite, mcp__github-gh__gh_pr_view, mcp__github-gh__gh_pr_checks, mcp__github-gh__gh_pr_merge, mcp__github-gh__gh_pr_diff, mcp__github-gh__gh_run_list, mcp__github-gh__gh_run_view]
---

# PR Review, Fix, Monitor, Merge Flow

Complete workflow to get a PR merged and continue with planned work.

## Auto-Detection

If no PR number provided, detect from:
1. Current branch name → find open PR for that branch
2. Most recent PR by current user
3. Ask user to specify

```bash
# Get PR for current branch
gh pr view --json number,title,state 2>/dev/null || gh pr list --head $(git branch --show-current) --json number,title --limit 1
```

## Steps

### 1. Review the PR
- Get PR details: `gh pr view <number> --json number,title,state,body,baseRefName,headRefName`
- Check CI status: `gh pr checks <number>`
- Review changes if needed: `gh pr diff <number>`

### 2. Identify Required vs Optional Checks

```bash
# Get repository rulesets to find required checks
gh api repos/{owner}/{repo}/rulesets | jq '.[].rules[] | select(.type=="required_status_checks") | .parameters.required_status_checks'
```

**Common required checks:** Build, Type Check, Lint, CI Summary
**Often optional:** E2E tests, Security Audit (if continue-on-error)

### 3. Fix Any Issues
If **required** CI checks are failing:
- Get failure details: `gh run view <run_id> --log-failed`
- Identify the root cause
- Make fixes, commit, push
- Wait for new CI run

### 4. Monitor CI
Poll until all **required** checks pass:

```bash
# Check if mergeable
gh pr view <number> --json mergeStateStatus,statusCheckRollup | jq '{
  status: .mergeStateStatus,
  checks: [.statusCheckRollup[] | {name, conclusion, status}]
}'
```

**Timeout:** 10 minutes max for standard checks, report progress every 30s.

### 5. Handle Merge Blockers

**Common issues and fixes:**

| Error | Cause | Fix |
|-------|-------|-----|
| `workflow scope` | PR modifies `.github/workflows/` | `gh auth refresh -s workflow` |
| `BLOCKED` status | Required checks pending/failed | Wait or fix failing checks |
| `MERGEABLE: CONFLICTING` | Merge conflicts | Rebase or merge main into branch |
| `review required` | Needs approval | Request review or check ruleset |

### 6. Merge the PR
Once ready:

```bash
gh pr merge <number> --squash --delete-branch
```

Confirm success and note the merge commit.

### 7. Continue with Plan
After merge:
1. `git checkout main && git pull`
2. Read active plan file
3. Identify and start next task

## Plan File Locations

Check in order:
1. `docs/plans/` (project-specific)
2. `~/.claude/plans/` (Claude session plans)
3. `/projects/plans/{project}/active/` (cross-project plans via filesystem MCP)

## Example Execution

```
1. Detected PR #70 from branch feat(platform)/cleanup
2. Required checks: Build ✅, Type Check ✅, Lint ✅, CI Summary ✅
3. Optional failing: E2E Tests (infrastructure issue, not blocking)
4. Merge state: MERGEABLE
5. Merging... ✅ Merged via squash
6. Switched to main, pulled changes
7. Next task from plan: Phase 4 - Testing Infrastructure
```
