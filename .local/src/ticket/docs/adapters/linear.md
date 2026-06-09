# MCP adapter: linear

Drive the **Linear MCP** when connected (e.g. `create_issue`, `update_issue`,
`get_issue`, `list_issue_statuses` / similar — Linear's MCP at
`https://mcp.linear.app/mcp`; confirm exact tool names against the connected
server). Else fall back to `ticket` (CLI, Linear GraphQL). Status: **# VERIFY**.

Config: `teamId`, `epicMap` (shorthand → **Linear project id**), `labelMap`
(state → workflow **state id**).

PR-line: **`Ticket: Linear <identifier>`** (e.g. `ENG-42`).

## Verbs → MCP calls

**resolve-epic `<shorthand>`** — read `epicMap[shorthand]` (a Linear project id). No MCP call.

**claim `<id>`**
1. `update_issue id:<id> stateId:<labelMap["in-dev"]>` (move to In Progress).
2. Return `Ticket: Linear <identifier>`.

**create `<projectId> <title> [--labels=a,b]`**
1. `create_issue teamId:<teamId> projectId:<projectId> title:"<title>"
   stateId:<in-dev>` → new issue `identifier`.
   (Area/priority: map to Linear labels if the MCP exposes `labelIds`; priority
   to Linear's `priority` 0–4 if available.)
2. Return `Ticket: Linear <identifier>`.

**done `<id>`** — `update_issue id:<id> stateId:<labelMap["done"]>`.

**pr-line `<id>`** — return `Ticket: Linear <id>` (no call).

## Notes

- Linear's MCP is remote (OAuth) and was historically wired in Cursor/Windsurf,
  not Claude — connect it before relying on this path.
- State ids and team/project ids are workspace-specific; pin them in config.
