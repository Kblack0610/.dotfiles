---
name: summary
description: Generate a comprehensive daily activity summary (GitHub PRs, commits, notes activity)
argument-hint: [date?]
allowed-tools: Bash, Read, Glob
---

# Daily Activity Summary

Generate a comprehensive summary of today's work activity. Sources are
git + the `gh` CLI (`gh-workflows` skill) + the user's `.notes/` system.
Linear is no longer used; GitHub MCP is intentionally NOT used (project
preference: `gh` CLI over MCP).

## Data Sources

Fetch data from all available sources in parallel:

### 1. GitHub Pull Requests
```bash
gh pr list --author=@me --state=all \
  --search "updated:>=$(date +%Y-%m-%d)" \
  --json number,title,state,url,headRefName,reviewDecision
```
Show: open PRs, merged today, review-requested.

### 2. GitHub Commits
```bash
git log --since=today --author="$(git config user.name)" --all \
  --pretty=format:'%h %s (%cr) [%cn]' --no-merges
```
Group by repo if multiple repos appear in the output.

### 3. PR Reviews
```bash
gh search prs --reviewed-by=@me --updated=">=$(date +%Y-%m-%d)"
gh search prs --review-requested=@me --state=open
```

### 4. Notes Activity
Read the user's notes for today and yesterday to surface stated focus,
priorities, decisions, and carry-over items:
```bash
TODAY_NOTE="$HOME/.notes/journal/daily/$(date +%Y-%m-%d).md"
TODAY_INBOX="$HOME/.notes/inbox/$(date +%Y-%m-%d).md"
[ -f "$TODAY_NOTE" ] && cat "$TODAY_NOTE"
[ -f "$TODAY_INBOX" ] && cat "$TODAY_INBOX"
```
Extract section headers (Focus, Priority, Notes, Carry Over, Current Projects)
+ key bullets. This is the user's actual planning surface — better signal
than scraping a tracker.

## Output Format

Present a clean, formatted summary:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📋 DAILY SUMMARY - {date}
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

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

📓 NOTES ACTIVITY
───────────────────────────────────────────────────────
Focus: API integration → DB migration
Priorities:
  • Ship HIPAA P1 PRs (#481-#483)
  • Review forms refactor PR
Decisions / carry-over:
  • Karakeep replacing Stash on home-k3s
  • Mobile billing flow blocked on Square SDK

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

## Execution Flow

1. **Parallel Fetch**: run `gh`/`git` commands + read notes files in parallel
2. **Aggregate**: combine all results
3. **Format**: present in the structured format above
4. **Highlight**: call out any urgent items or blockers

## Optional Arguments

- `$ARGUMENTS` can be a date in YYYY-MM-DD format to fetch summary for a specific day
- Default: today

### 5. Repository Analysis (if available)

Check for today's analysis results and include if present:

```bash
ANALYSIS_FILE="$HOME/.claude/cache/analysis-$(date +%Y-%m-%d).json"
if [[ -f "$ANALYSIS_FILE" ]]; then
  # Include analysis summary
fi
```

Add to output format if analysis data exists:
```
🔍 REPOSITORY ANALYSIS
───────────────────────────────────────────────────────
Security: {critical} critical, {high} high, {medium} medium
Quality: {issues} issues ({auto_fixed} auto-fixed)
Dependencies: {outdated} outdated ({major} major updates)
Actions: {prs} PRs created, {issues} GitHub issues created
```

## Notes

- Uses `gh` CLI (per `gh-workflows` skill) + git + filesystem reads
- `gh` auth comes from `gh auth login` state, not MCP server config
- Notes activity reads `~/.notes/journal/daily/<date>.md` + `~/.notes/inbox/<date>.md`
- Analysis data from `/daily:analysis` is automatically included if available
