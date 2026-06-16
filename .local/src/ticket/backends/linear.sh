#!/usr/bin/env bash
# linear backend — MINIMAL. Linear GraphQL API.
#
# Config (project-map.json trackers.<project>):
#   { "system":"linear", "tokenEnv":"LINEAR_API_KEY",
#     "teamId":"<uuid>",
#     "epicMap":  { "ci":"<projectId>", ... },     # shorthand -> Linear project id
#     "labelMap": { "in-dev":"<stateId>","done":"<stateId>" } }  # state -> workflow state id
#
# Contract-complete but only create/claim/done/pr-line/resolve-epic are wired;
# enough for the kb Phase-0 flow. pr-line: `Ticket: Linear <identifier>`.
#
# VERIFY LIVE: never exercised against a live workspace. State/team/project ids
# are workspace-specific. Treat as a starting point.

_ln_token() { resolve_token LINEAR_API_KEY \
                || die "no token: set tracker.tokenEnv (or LINEAR_API_KEY)"; }

# ln_gql QUERY VARIABLES_JSON
ln_gql() {
  local query="$1" token body
  local vars="${2:-}"; [[ -n "$vars" ]] || vars='{}'
  token=$(_ln_token)
  body=$(jq -nc --arg q "$query" --argjson v "$vars" '{query:$q, variables:$v}')
  http POST "https://api.linear.app/graphql" "$body" \
    -H "Authorization: $token" -H "Content-Type: application/json"
}

tb_pr_line() { echo "Ticket: Linear ${1:?id}"; }

tb_resolve_epic() {
  local area="${1:?usage: resolve-epic <shorthand>}" id
  id=$(cfg ".epicMap[\"$area\"]")
  [[ -n "$id" ]] || die "no epic mapping for '$area' (add trackers.<project>.epicMap = Linear project id)"
  echo "$id"
}

tb_create() {
  local project="${1:?usage: create <projectId> <title> [--labels=..]}" title="${2:?title required}"
  local team state vars resp ident
  team=$(cfg '.teamId'); [[ -n "$team" ]] || die "tracker config missing .teamId"
  state=$(cfg '.labelMap["in-dev"]')
  vars=$(jq -nc --arg t "$team" --arg p "$project" --arg s "$title" --arg st "$state" \
    '{input:({teamId:$t, projectId:$p, title:$s} + (if $st=="" then {} else {stateId:$st} end))}')
  resp=$(ln_gql 'mutation($input:IssueCreateInput!){issueCreate(input:$input){success issue{identifier}}}' "$vars")
  ident=$(printf '%s' "$resp" | jq -r '.data.issueCreate.issue.identifier // .key // empty')
  [[ -n "$ident" ]] || die "issue creation failed: $resp"
  tb_pr_line "$ident"
}

tb_claim() {
  local id="${1:?usage: claim <issue-id>}" state vars
  state=$(cfg '.labelMap["in-dev"]')
  if [[ -n "$state" ]]; then
    vars=$(jq -nc --arg i "$id" --arg s "$state" '{id:$i, input:{stateId:$s}}')
    ln_gql 'mutation($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success}}' "$vars" >/dev/null
  fi
  tb_pr_line "$id"
}

tb_done() {
  local id="${1:?usage: done <issue-id>}" state vars
  state=$(cfg '.labelMap["done"]'); [[ -n "$state" ]] || { warn "no done stateId in labelMap"; return 0; }
  vars=$(jq -nc --arg i "$id" --arg s "$state" '{id:$i, input:{stateId:$s}}')
  ln_gql 'mutation($id:String!,$input:IssueUpdateInput!){issueUpdate(id:$id,input:$input){success}}' "$vars" >/dev/null
}
