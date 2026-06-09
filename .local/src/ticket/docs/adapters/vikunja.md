# MCP adapter: vikunja

Drive the **`vikunja` MCP** (tools `vikunja_tasks`, `vikunja_projects`,
`vikunja_labels`, `vikunja_auth`; each takes a `subcommand`). Use this when the
vikunja MCP is connected; otherwise fall back to `ticket` (CLI). Status: **live**.

Label/epic ids come from `trackers.<project>` in project-map.json (state
`in-dev`=1 `blocked`=2 `done`=3 `todo`=16; area `web`=5 `api`=6 `mobile`=7
`infra`=8 `ci`=9 `security`=10 `compliance`=11; priority `P0`=12…`P3`=15).

PR-line: **`Vikunja: <id>`** (legacy form — keeps bnb/platform CI matching).

## Verbs → MCP calls

**preflight** — `vikunja_auth subcommand:"status"` once; if not authed, stop and report.

**resolve-epic `<shorthand>`** — read the id from config `epicMap[shorthand]` (no
MCP call needed). For discovery, `vikunja_projects subcommand:"get-tree"` (parents
3 and 9) lists epics.

**claim `<id>`**
1. `vikunja_tasks subcommand:"get" id:<id>` → note `project_id`.
2. `vikunja_tasks subcommand:"remove-label" id:<id> labelId:16` (Todo; ignore if absent).
3. `vikunja_tasks subcommand:"apply-label" id:<id> labelId:1` (In Development).
4. Move to Doing: find the project's kanban view + "Doing" bucket
   (`vikunja_projects subcommand:"get" id:<project_id>` / views), then
   `POST /projects/<pid>/views/<vid>/buckets/<doing>/tasks {"task_id":<id>}`
   (bucket move has no MCP verb — use the raw API with the MCP's token, or the CLI).
5. Return `Vikunja: <id>`.

**create `<epic> <title> [--labels=a,b]`**
1. `vikunja_tasks subcommand:"create" projectId:<epic> title:"<title>"` → new `id`.
2. For each label name → id (config `labelMap`), `vikunja_tasks subcommand:"apply-label" id:<new> labelId:<lid>`. Always include `1` (In Development).
3. Move to Doing (as in claim step 4).
4. Return `Vikunja: <new id>`.

**done `<id>`** — `vikunja_tasks subcommand:"update" id:<id> done:true`, then
`apply-label labelId:3` (Done). The `vikunja-close-on-merge.yml` CI action usually
does this on merge, so the agent rarely calls it.

**pr-line `<id>`** — return `Vikunja: <id>` (no call).

## Notes

- The bucket move is the one step with no MCP verb; the CLI backend handles it via
  raw API. In MCP mode, either call the raw endpoint with the MCP token or just run
  `ticket claim/create` for the whole flow — both produce `Vikunja: <id>`.
- Large tree operations: delegate to a subagent to keep main context clean.
