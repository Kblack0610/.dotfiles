# MCP adapter: jira (Atlassian)

Drive the **Atlassian MCP** when connected (tools: `getJiraIssue`,
`createJiraIssue`, `editJiraIssue`, `searchJiraIssuesUsingJql`,
`transitionJiraIssue`, `getTransitionsForJiraIssue`; most take a `cloudId`).
Else fall back to `ticket` (CLI, Jira REST v3). Status: **# VERIFY** (not run live here).

Config: `instance` (site host), `projectKey`, `issueType`, `epicMap` (shorthand →
epic key), `labelMap` (state → transition id). The MCP needs the site `cloudId` —
discover it once via the MCP's accessible-resources tool and cache it.

PR-line: **`Ticket: Jira <KEY>`**.

## Verbs → MCP calls

**resolve-epic `<shorthand>`** — read `epicMap[shorthand]` from config (an epic
issue key, e.g. `ABC-100`). No MCP call.

**claim `<key>`**
1. `getTransitionsForJiraIssue cloudId:<c> issueIdOrKey:<key>` → find the
   "In Development"/"In Progress" transition (or use `labelMap["in-dev"]`).
2. `transitionJiraIssue cloudId:<c> issueIdOrKey:<key> transition:{id:<tid>}`.
3. Return `Ticket: Jira <key>`.

**create `<epic-key> <title> [--labels=a,b]`**
1. `createJiraIssue cloudId:<c> projectKey:<projectKey> issueTypeName:<issueType>
   summary:"<title>" parentKey:<epic-key> labels:[<area/priority names>]`
   (state names like `in-dev` are NOT labels — they drive the transition below).
2. `transitionJiraIssue` → "In Development" (as in claim).
3. Return `Ticket: Jira <new key>`.

**done `<key>`** — `transitionJiraIssue` → the Done transition (`labelMap["done"]`).

**pr-line `<key>`** — return `Ticket: Jira <key>` (no call).

## Notes

- Transition ids are workflow-specific — always confirm via
  `getTransitionsForJiraIssue` (or pin them in `labelMap`).
- Jira "epic link" on team-managed projects is the `parent` field; on
  company-managed projects it may be a custom field (`customfield_*`) — verify per site.
