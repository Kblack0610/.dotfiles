---
name: memory-sync
description: Review recent activity and update persistent memory systems with durable project, infrastructure, and preference learnings.
---

# Memory Sync

Use this skill when the user wants to sync memories, capture recent learnings, or keep long-lived context updated.

## Workflow

1. Read `~/.config/nightly/config.toml` to see which sources are enabled.
2. Gather recent activity from enabled sources such as git history, Linear, inbox notes, and journal notes.
3. Check existing memories before writing to avoid duplication.
4. Store durable personal, project, or infrastructure facts in the appropriate memory system.
5. Write a short sync report summarizing what changed.

## What to store

Good candidates:
- architecture decisions
- repeated implementation patterns
- stable workflow preferences
- project-specific technical facts that will matter later

Skip:
- vague work summaries
- one-off noise with no reuse value
- duplicated facts already present in memory
