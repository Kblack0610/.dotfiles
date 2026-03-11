---
name: binks-agent
description: Delegate autonomous tasks to the local binks agent when the request is better handled by your external orchestration stack or specialized MCP servers.
---

# Binks Agent

Use this skill when the user wants work performed by the local binks agent rather than directly in Codex.

## When to use it

- The task is operational and better suited to your broader MCP stack.
- The user explicitly mentions binks.
- The work needs tools or context Codex does not have directly.

## Workflow

1. Restate the task in a single concrete sentence.
2. Use the `binks-agent` MCP/tool surface if available.
3. Pass the task as the message payload.
4. If the task is narrow, limit server scope to the smallest useful set.
5. Return the outcome, open issues, and any follow-up needed from Codex.

## Guardrails

- Do not invent binks capabilities that are not available.
- If the binks surface is unavailable, say that briefly and continue with the best direct fallback.
