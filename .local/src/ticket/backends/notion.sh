#!/usr/bin/env bash
# notion backend — MINIMAL. Notion API (a database row = a ticket).
#
# Config (project-map.json trackers.<project>):
#   { "system":"notion", "tokenEnv":"NOTION_API_TOKEN",
#     "instance":"2022-06-28",                       # Notion-Version (optional)
#     "epicMap":  { "ci":"<databaseId>", ... },      # shorthand -> database id
#     "statusProp":"Status", "titleProp":"Name",
#     "labelMap": { "in-dev":"In Progress","done":"Done" } }  # state -> Status option
#
# Contract-complete but minimal: create/claim/done/pr-line/resolve-epic only.
# pr-line: `Ticket: Notion <pageId>`.
#
# VERIFY LIVE: never exercised against a live workspace. Database/property names
# are workspace-specific. Treat as a starting point.

_no_token()   { resolve_token NOTION_API_TOKEN NOTION_TOKEN \
                  || die "no token: set tracker.tokenEnv (or NOTION_API_TOKEN)"; }
_no_version() { cfg '.instance' '2022-06-28'; }

# no_api METHOD PATH [body]
no_api() {
  local method="$1" path="$2" body="${3:-}" token
  token=$(_no_token)
  http "$method" "https://api.notion.com/v1$path" "$body" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json" \
    -H "Notion-Version: $(_no_version)"
}

tb_pr_line() { echo "Ticket: Notion ${1:?id}"; }

tb_resolve_epic() {
  local area="${1:?usage: resolve-epic <shorthand>}" id
  id=$(cfg ".epicMap[\"$area\"]")
  [[ -n "$id" ]] || die "no epic mapping for '$area' (add trackers.<project>.epicMap = database id)"
  echo "$id"
}

tb_create() {
  local db="${1:?usage: create <databaseId> <title> [--labels=..]}" title="${2:?title required}"
  local title_prop status_prop status body resp pid
  title_prop=$(cfg '.titleProp' 'Name')
  status_prop=$(cfg '.statusProp' 'Status')
  status=$(cfg '.labelMap["in-dev"]' 'In Progress')
  body=$(jq -nc --arg db "$db" --arg tp "$title_prop" --arg t "$title" --arg sp "$status_prop" --arg s "$status" \
    '{parent:{database_id:$db}, properties:( {($tp):{title:[{text:{content:$t}}]}} + {($sp):{status:{name:$s}}} )}')
  resp=$(no_api POST "/pages" "$body")
  pid=$(printf '%s' "$resp" | jq -r '.id')
  [[ -n "$pid" && "$pid" != "null" ]] || die "page creation failed: $resp"
  tb_pr_line "$pid"
}

_no_set_status() {
  local pid="$1" state="$2" status_prop status body
  status_prop=$(cfg '.statusProp' 'Status')
  status=$(cfg ".labelMap[\"$state\"]"); [[ -n "$status" ]] || { warn "no '$state' status in labelMap"; return 0; }
  body=$(jq -nc --arg sp "$status_prop" --arg s "$status" '{properties:{($sp):{status:{name:$s}}}}')
  no_api PATCH "/pages/$pid" "$body" >/dev/null
}

tb_claim() { local pid="${1:?usage: claim <pageId>}"; _no_set_status "$pid" "in-dev"; tb_pr_line "$pid"; }
tb_done()  { local pid="${1:?usage: done <pageId>}";  _no_set_status "$pid" "done"; }
