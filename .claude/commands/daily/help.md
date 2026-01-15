---
name: help
description: List all available /daily commands
allowed-tools: []
---

# /daily Commands

Commands for generating daily activity summaries and standup reports.

| Command | Description |
|---------|-------------|
| `/daily:summary` | Full daily activity summary (Linear, GitHub PRs, commits, reviews) |
| `/daily:standup` | Concise standup format (yesterday, today, blockers) |
| `/daily:slack` | Slack-formatted summary with optional webhook posting |
| `/daily:analysis` | Repo analysis (security, quality, deps) with auto-PRs and Linear tickets |
| `/daily:help` | This help message |

## Data Sources

All `/daily` commands pull from:
- **Linear** (via MCP): Your assigned issues, state changes, completions
- **GitHub** (via MCP): PRs authored, commits, reviews given/requested

## Quick Examples

```bash
# Full summary of today's activity
/daily:summary

# Quick standup update
/daily:standup

# Standup formatted for Slack
/daily:standup --slack

# Generate Slack message (dry run)
/daily:slack --dry-run

# Summary for a specific date
/daily:summary 2025-01-14

# Run repo analysis (security, quality, dependencies)
/daily:analysis

# Analysis dry-run (no PRs or tickets created)
/daily:analysis --dry-run

# Headless analysis for automation
claude --dangerously-skip-permissions -p "/daily:analysis"
```

## Requirements

- Linear MCP server configured (for ticket data)
- GitHub MCP server configured (for PR/commit data)
- Both should already be set up in your Claude Code config
