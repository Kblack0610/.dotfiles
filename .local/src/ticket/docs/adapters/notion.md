# MCP adapter: notion

Drive the **Notion MCP** when connected (e.g. `API-post-page`,
`API-patch-page`, `API-post-database-query` — names depend on the MCP build;
confirm against the connected server). Else fall back to `ticket` (CLI, Notion
API). Status: **# VERIFY**. A ticket = a row (page) in a database.

Config: `epicMap` (shorthand → **database id**), `titleProp` (default `Name`),
`statusProp` (default `Status`), `labelMap` (state → Status option name).

PR-line: **`Ticket: Notion <pageId>`**.

## Verbs → MCP calls

**resolve-epic `<shorthand>`** — read `epicMap[shorthand]` (a database id). No MCP call.

**claim `<pageId>`**
1. Patch the page's `statusProp` → `labelMap["in-dev"]` (e.g. "In Progress").
2. Return `Ticket: Notion <pageId>`.

**create `<databaseId> <title> [--labels=a,b]`**
1. Create a page: `parent.database_id:<db>`, set `titleProp` title to `<title>`,
   `statusProp` to the in-dev option. (Area/priority → a multi-select prop if the
   DB has one; otherwise omit.)
2. Return `Ticket: Notion <new pageId>`.

**done `<pageId>`** — patch `statusProp` → `labelMap["done"]` (e.g. "Done").

**pr-line `<pageId>`** — return `Ticket: Notion <pageId>` (no call).

## Notes

- Property names and Status option names are **database-specific** — they must
  match the target DB's schema exactly. Inspect via the MCP's retrieve-database tool.
- The integration must be shared with the target database, or writes 404.
