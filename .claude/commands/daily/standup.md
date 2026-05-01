---
name: standup
description: Generate a concise standup update (yesterday, today, blockers)
argument-hint: [format?]
allowed-tools: Bash
---

# Daily Standup Generator

Generate a concise standup update in the classic format. Sources are git +
the `gh` CLI (`gh-workflows` skill) — Linear is no longer used; GitHub MCP
is intentionally NOT used (project preference: `gh` CLI over MCP).

## Workflow

1. **Fetch Yesterday's Activity**
   - Commits across active repos:
     ```bash
     git log --since="yesterday 00:00" --until="today 00:00" \
       --author="$(git config user.name)" --all --oneline
     ```
   - Merged PRs:
     ```bash
     gh pr list --author=@me --state=merged \
       --search "merged:>=$(date -d yesterday +%Y-%m-%d)"
     ```
   - Reviews given yesterday:
     ```bash
     gh search prs --reviewed-by=@me \
       --updated=">=$(date -d yesterday +%Y-%m-%d)"
     ```

2. **Fetch Today's Plan**
   - Open PRs needing attention:
     ```bash
     gh pr list --author=@me --state=open
     ```
   - Current branch + uncommitted WIP:
     ```bash
     git status --short && git branch --show-current
     ```
   - Optionally: today's notes for stated focus
     ```bash
     [ -f ~/.notes/journal/daily/$(date +%Y-%m-%d).md ] && \
       grep -A 5 -i '^## Focus\|^## Priority' ~/.notes/journal/daily/$(date +%Y-%m-%d).md
     ```

3. **Identify Blockers**
   - PRs waiting on review for >24h:
     ```bash
     gh pr list --author=@me --state=open \
       --json url,title,createdAt,reviewDecision | \
       jq '.[] | select(.reviewDecision == null and ((now - (.createdAt | fromdateiso8601)) > 86400))'
     ```
   - Draft PRs not touched in >3 days:
     ```bash
     gh pr list --author=@me --draft --json url,title,updatedAt | \
       jq '.[] | select((now - (.updatedAt | fromdateiso8601)) > 259200)'
     ```
   - Optionally: blocker callouts in today's notes:
     ```bash
     grep -i blocked ~/.notes/journal/daily/$(date +%Y-%m-%d).md
     ```

## Output Format

```
📍 STANDUP - {date}

✅ YESTERDAY
• Merged PR #42 — Add user authentication (repo-name)
• 7 commits in repo-a (auth/migrations + bug-fix-x)
• Reviewed PR #55 for @teammate

📋 TODAY
• PR #48 ready for review (repo-name)
• On branch `feature/api-integration` (3 uncommitted files)
• Today's focus: API integration → DB migration

⚠️ BLOCKERS
• PR #45 waiting on @specific-reviewer (>2 days)
• Draft PR #30 stalled — needs spec sign-off
```

## Argument Options

- `--slack` or `slack`: Format for Slack (uses mrkdwn)
- `--markdown` or `md`: Format as clean markdown
- `--plain` or `text`: Plain text format (default)

## Copy-Paste Ready

The output should be immediately copy-paste ready for:
- Slack standup channels
- DailyBot responses
- Team standup meetings
- Status updates
