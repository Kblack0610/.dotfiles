# Tracker Contract — system-agnostic ticketing for the kb workflow

The kb pipeline (`/kb:workflow`, `/kb:implement`) never hard-codes a ticketing
system. It speaks an abstract **tracker contract**; provider mechanics live
behind per-system adapters selected per-repo. Adding a new tracker = one MCP
adapter spec + (optionally) one CLI backend + one config block, with **zero**
changes to the kb commands.

- Config: `~/.dotfiles/.config/shared-hooks/project-map.json` → `trackers`
- MCP adapters: `docs/adapters/<system>.md` (agent-driven, **preferred**)
- CLI backends: `backends/<system>.sh` via the `ticket` binary (mechanical fallback)

## Two execution modes

A ticket write happens one of two ways. **The agent picks per repo + what's connected:**

1. **MCP-driven (preferred).** When the active system's MCP server is connected
   (the agent can see its tools), the **agent drives the MCP directly** following
   `docs/adapters/<system>.md`. This is the normal interactive path and uses
   whatever auth the MCP already holds — different tool surface for every system.
2. **CLI (mechanical fallback).** When no MCP is connected (headless `kb-coordinator`
   / CI, fresh machine, or a system whose MCP isn't wired), the agent runs the
   `ticket` CLI, which hits the system's REST/GraphQL API with a token.

> A bash CLI cannot call MCP tools — MCP is an agent↔server protocol. That's why
> the MCP path is agent-driven (adapter spec) and the CLI path is curl-driven.
> Both honor the same verbs and the same PR-line format, so the kb flow is identical.

## The verbs

| Verb | Args | result | Purpose |
|------|------|--------|---------|
| `system` | — | `vikunja` | active backend for the current repo |
| `resolve-epic` | `<shorthand>` | `24` | map a shorthand (`ci`,`mobile`,`release`…) → epic/parent id |
| `claim` | `<id>` | PR-line | mark In-Dev, move to Doing, return the ref |
| `create` | `<epic> <title> [--labels=a,b]` | PR-line | create a story under epic, label, move to Doing |
| `done` | `<id>` | — | mark Done (CI close-on-merge usually owns this) |
| `pr-line` | `<id>` | e.g. `Vikunja: 213` | the exact PR-body line for an id |

## PR-line ownership (the compatibility lever)

The **adapter/backend** decides the PR-body line — both modes agree:

- **vikunja** emits the legacy `Vikunja: <id>` so bnb/platform's CI
  (`vikunja-pr-gate.yml`, `vikunja-close-on-merge.yml`) keeps matching untouched.
- every other system emits `Ticket: <System> <id>` (e.g. `Ticket: Jira HLX-12`).

The kb command never hard-codes the line — it captures whatever the verb returns.

## Abstract label vocabulary

Pass these names to `--labels`; each adapter maps them to its own ids/transitions/tags:

- **state**: `in-dev`, `blocked`, `done`, `todo`
- **area**: `web`, `api`, `mobile`, `infra`, `ci`, `security`, `compliance`
- **priority**: `P0`–`P3`

`area:` / `priority:` / `state:` prefixes are stripped, so PR-template-style
names (`area:ci`, `priority:P2`) also work.

## Resolution order (which system runs, and how)

1. **Repo-local override** — an executable `scripts/ticket.sh` in the repo root
   implementing the verb contract. If present, the CLI execs it.
2. **Per-project config** — `trackers.<project-name>` in `project-map.json`
   (project resolved by repo path via `project-name.sh`).
3. **Default** — `trackers.default`.
4. **none / unresolved** → the kb flow writes `Ticket: none — <reason>` and
   continues. Work is never blocked.

Given the resolved `system`, the agent then chooses the **mode**: MCP if that
system's MCP is connected (drive per `docs/adapters/<system>.md`), else the CLI.

## Systems

| System | MCP adapter | CLI backend | Auth (CLI mode) | Epic id is… |
|--------|-------------|-------------|-----------------|-------------|
| `vikunja` | `adapters/vikunja.md` (live) | full (reference) | `VIKUNJA_MCP_TOKEN`/`VIKUNJA_API_TOKEN` | a project id |
| `jira` | `adapters/jira.md` · `# VERIFY` | full · `# VERIFY LIVE` | `JIRA_API_TOKEN`+`JIRA_EMAIL` | an epic issue key |
| `clickup` | `adapters/clickup.md` · `# VERIFY` | full · `# VERIFY LIVE` | `CLICKUP_API_TOKEN` | a List id |
| `linear` | `adapters/linear.md` · `# VERIFY` | minimal | `LINEAR_API_KEY` | a Linear project id |
| `notion` | `adapters/notion.md` · `# VERIFY` | minimal | `NOTION_API_TOKEN` | a database id |
| `local` | — (offline) | full (offline) | — | a heading in `~/.agent/todos/<project>.md` |
| `none` | — | sentinel | — | — |

`# VERIFY`: the MCP adapter / CLI request shapes are written from each provider's
docs but have not been exercised against a live instance on this machine.

## Current wiring (this machine)

- **home / personal** → `vikunja` (also `trackers.default`)
- **bnb-platform** → `vikunja` (epic + label maps in config)
- **"gigantic playground"** → `clickup` *(template in this doc — fill in path + List ids)*
- **Deloitte** → `jira` *(template in this doc — fill in path + project key)*

## Adding a tracker in 3 steps

1. Add the repo path to `project-map.json` `paths` (so it resolves to a name).
2. Add a `trackers.<name>` block (templates below).
3. Wire **one** write path: either the system's MCP (then write `adapters/<name>.md`)
   or a token for the CLI backend. Verify with `ticket --dry-run create …` (CLI)
   or a dry MCP read.

### ClickUp template (e.g. "gigantic playground")

```jsonc
"playground": {
  "system": "clickup",
  "tokenEnv": "CLICKUP_API_TOKEN",
  "epicMap":  { "ci": "<listId>", "web": "<listId>" },   // shorthand -> List id
  "labelMap": { "in-dev": "in progress", "done": "complete" }  // state -> status name
}
```

### Jira template (e.g. Deloitte)

```jsonc
"deloitte": {
  "system": "jira",
  "instance": "deloitte.atlassian.net",
  "projectKey": "ABC",
  "issueType": "Task",
  "tokenEnv": "JIRA_API_TOKEN",
  "emailEnv": "JIRA_EMAIL",
  "epicMap":  { "ci": "ABC-100" },                  // shorthand -> epic issue key
  "labelMap": { "in-dev": "21", "done": "41" }      // state -> workflow transition id
}
```

## kb Phase-0 usage (tracker-agnostic, MCP-first)

```bash
SYS=$(ticket system 2>/dev/null || echo none)
```

Then:
- `SYS=none` → `TICKET_LINE="Ticket: none — no tracker configured for this repo"`.
- else if the **`$SYS` MCP is connected** → drive it per `docs/adapters/$SYS.md`
  (claim the supplied id, or resolve-epic + create), capturing the PR-line.
- else → use the CLI: `ticket claim <id>` / `ticket create $(ticket resolve-epic <area>) "<title>" --labels=…`.

The PR body carries `$TICKET_LINE` verbatim (`Vikunja: 213` or `Ticket: Jira ABC-9`).
