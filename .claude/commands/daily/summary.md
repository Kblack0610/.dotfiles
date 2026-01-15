---
name: summary
description: Generate a comprehensive daily activity summary (Linear tickets, GitHub PRs, commits)
argument-hint: [date?]
allowed-tools: mcp__linear__*, mcp__github__*, Bash, Read
---

# Daily Activity Summary

Generate a comprehensive summary of today's work activity across all platforms.

## Data Sources

Fetch data from all available sources in parallel:

### 1. Linear Tasks
Use `mcp__linear__list_issues` with:
- `assignee`: "me"
- `updatedAt`: "-P1D" (last 24 hours)
- `limit`: 50

Group by state: In Progress, Completed, Backlog

### 2. GitHub Pull Requests
Use `mcp__github__search_pull_requests` with:
- `query`: "author:@me"
- `owner`: (detect from current repo or use default)

Show: Open PRs, Merged today, Review requested

### 3. GitHub Commits
Use `mcp__github__list_commits` for recent repos with:
- `author`: (current GitHub user)
- Today's commits across active repositories

### 4. PR Reviews
Use `mcp__github__search_pull_requests` with:
- `query`: "reviewed-by:@me" or "review-requested:@me"

## Output Format

Present a clean, formatted summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 DAILY SUMMARY - {date}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

🎯 LINEAR TASKS
───────────────────────────────────────────────────────
In Progress:
  • [TICKET-123] Task title (Project Name)
  • [TICKET-456] Another task

Completed Today:
  • [TICKET-789] Finished task ✓

Blocked/Waiting:
  • [TICKET-101] Blocked task ⚠️

💻 GITHUB ACTIVITY
───────────────────────────────────────────────────────
Open PRs:
  • #42 PR title (repo-name) - Ready for review
  • #38 Another PR (repo-name) - Draft

Merged Today:
  • #40 Merged PR (repo-name) ✓

Commits Today: 12 commits across 3 repos
  • repo-a: 5 commits
  • repo-b: 4 commits
  • repo-c: 3 commits

👀 REVIEWS
───────────────────────────────────────────────────────
Pending Review Requests:
  • #55 PR needing review (other-repo) by @teammate

Reviews Given:
  • #52 Approved PR (repo-name)

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Execution Flow

1. **Parallel Fetch**: Call Linear and GitHub MCP tools simultaneously
2. **Aggregate**: Combine all results
3. **Format**: Present in the structured format above
4. **Highlight**: Call out any urgent items or blockers

## Optional Arguments

- `$ARGUMENTS` can be a date in YYYY-MM-DD format to fetch summary for a specific day
- Default: today

## Notes

- Uses MCP servers directly - no external API keys needed for Linear/GitHub
- Linear API key comes from Linear MCP server config
- GitHub token comes from GitHub MCP server config
