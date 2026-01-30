---
name: standup
description: Generate a concise standup update (yesterday, today, blockers)
argument-hint: [format?]
allowed-tools: mcp__linear__*, mcp__github__*, Bash
---

# Daily Standup Generator

Generate a concise standup update in the classic format.

## Workflow

1. **Fetch Yesterday's Activity**
   - Linear: `mcp__linear__list_issues` with `assignee: "me"`, `state: "completed"`, `updatedAt: "-P1D"`
   - GitHub: `mcp__github__search_pull_requests` with `query: "author:@me merged:>=yesterday"`

2. **Fetch Today's Plan**
   - Linear: `mcp__linear__list_issues` with `assignee: "me"`, `state: "started"` or `state: "todo"`
   - GitHub: `mcp__github__list_pull_requests` with `state: "open"`

3. **Identify Blockers**
   - Linear issues with "blocked" label or in blocked state
   - PRs waiting on review for >24 hours

## Output Format

```
📍 STANDUP - {date}

✅ YESTERDAY
• Completed [TICKET-123] Feature implementation
• Merged PR #42 - Add user authentication
• Reviewed PR #55 for @teammate

📋 TODAY
• Working on [TICKET-456] API integration
• PR #48 ready for review
• Planning [TICKET-789] Database migration

⚠️ BLOCKERS
• [TICKET-101] Waiting on design specs
• PR #45 needs review from @specific-reviewer
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
