---
description: Invoke the binks agent for autonomous tasks via local LLM
argument-hint: Task description for binks agent
---

# Binks Agent

You are invoking the binks agent - a local LLM-powered agent with MCP tools (kubernetes, ssh, github, sysinfo, filesystem, etc.).

## Task
$ARGUMENTS

## Instructions
1. Use the `mcp__binks-agent__agent_chat` tool to send the task to binks
2. Pass the task description as the `message` parameter
3. Optionally filter to specific MCP servers if the task is focused (e.g., `["sysinfo", "kubernetes"]`)
4. Report the results back to the user

Example invocation:
```
mcp__binks-agent__agent_chat({
  "message": "$ARGUMENTS",
  "servers": null  // or ["github-gh", "sysinfo"] for focused tasks
})
```
