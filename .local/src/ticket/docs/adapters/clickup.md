# MCP adapter: clickup

Drive a **ClickUp MCP** when connected (e.g. `clickup_create_task`,
`clickup_update_task`, `clickup_get_task`, or a generic `clickup` tool with an
action/subcommand — tool names vary by MCP build; confirm against the connected
server). Else fall back to `ticket` (CLI, ClickUp API v2). Status: **# VERIFY**.

Config: `epicMap` (shorthand → **List id**), `labelMap` (state → status name,
e.g. `in-dev`→"in progress", `done`→"complete"). ClickUp hierarchy:
Space > Folder > List > Task; epics map to List ids.

PR-line: **`Ticket: ClickUp <id>`**.

## Verbs → MCP calls

**resolve-epic `<shorthand>`** — read `epicMap[shorthand]` (a List id). No MCP call.

**claim `<id>`**
1. Update task status → `labelMap["in-dev"]` (e.g. `clickup_update_task
   task_id:<id> status:"in progress"`).
2. Return `Ticket: ClickUp <id>`.

**create `<list-id> <title> [--labels=a,b]`**
1. Create in list → `clickup_create_task list_id:<list> name:"<title>"
   status:<in-dev status> tags:[<area/priority names>]` (state names are not tags).
2. Return `Ticket: ClickUp <new id>`.

**done `<id>`** — update status → `labelMap["done"]` (e.g. "complete").

**pr-line `<id>`** — return `Ticket: ClickUp <id>` (no call).

## Notes

- Statuses are **per-list strings** — the abstract `in-dev`/`done` must map to a
  status that exists on the target list. Verify via the MCP's get-list/statuses tool.
- Priority in ClickUp is an enum (1=urgent…4=low); map `P0..P3` to it if the MCP
  exposes a priority field, otherwise keep them as tags.
