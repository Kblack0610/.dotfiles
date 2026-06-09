#!/usr/bin/env bash
# clickup backend — ClickUp API v2.
#
# Config (project-map.json trackers.<project>):
#   { "system":"clickup", "tokenEnv":"CLICKUP_API_TOKEN",
#     "epicMap":  { "ci":"901100123", ... },        # shorthand -> List id
#     "labelMap": { "in-dev":"in progress","done":"complete",  # state -> status name
#                   "ci":"ci","P2":"priority:2" } }  # area -> tag, priority -> status/tag
#
# ClickUp hierarchy: Space > Folder > List > Task. Epics map to List ids.
# state names map to ClickUp statuses (per-list strings) via labelMap; other
# labels become ClickUp tags. pr-line: `Ticket: ClickUp <id>`.
#
# VERIFY LIVE: dry-run-verified request shapes; statuses are list-specific —
# confirm against a real ClickUp workspace before trusting writes.

_cu_base() { echo "https://api.clickup.com/api/v2"; }
_cu_token() { resolve_token CLICKUP_API_TOKEN \
                || die "no token: set tracker.tokenEnv (or CLICKUP_API_TOKEN)"; }

# cu_api METHOD PATH [body]
cu_api() {
  local method="$1" path="$2" body="${3:-}" token
  token=$(_cu_token)
  http "$method" "$(_cu_base)$path" "$body" \
    -H "Authorization: $token" -H "Content-Type: application/json"
}

# Abstract status name -> ClickUp status (labelMap), default to the name itself.
_cu_status() { local s; s=$(cfg ".labelMap[\"$1\"]"); echo "${s:-$1}"; }

tb_pr_line() { echo "Ticket: ClickUp ${1:?id}"; }

tb_resolve_epic() {
  local area="${1:?usage: resolve-epic <shorthand>}" id
  id=$(cfg ".epicMap[\"$area\"]")
  [[ -n "$id" ]] || die "no epic mapping for '$area' (add trackers.<project>.epicMap = List id)"
  echo "$id"
}

tb_claim() {
  local id="${1:?usage: claim <task-id>}" status
  status=$(_cu_status "in-dev")
  cu_api PUT "/task/$id" "$(jq -nc --arg s "$status" '{status:$s}')" >/dev/null
  tb_pr_line "$id"
}

tb_create() {
  local list="${1:?usage: create <list-id> <title> [--labels=..]}" title="${2:?title required}" labels_arg="${3:-}"
  local tags_json='[]'
  if [[ "$labels_arg" == --labels=* ]]; then
    local lcsv="${labels_arg#--labels=}" raw lname
    local arr=()
    IFS=',' read -ra parts <<< "$lcsv"
    for raw in "${parts[@]}"; do
      lname="${raw#area:}"; lname="${lname#priority:}"; lname="${lname#state:}"
      case "$lname" in in-dev|blocked|done|todo) continue ;; esac
      arr+=("$lname")
    done
    tags_json=$(printf '%s\n' "${arr[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')
  fi

  local status body resp tid
  status=$(_cu_status "in-dev")
  body=$(jq -nc --arg n "$title" --arg s "$status" --argjson tags "$tags_json" \
    '{name:$n, status:$s, tags:$tags}')
  resp=$(cu_api POST "/list/$list/task" "$body")
  tid=$(printf '%s' "$resp" | jq -r '.id')
  [[ -n "$tid" && "$tid" != "null" ]] || die "task creation failed: $resp"
  tb_pr_line "$tid"
}

tb_done() {
  local id="${1:?usage: done <task-id>}" status
  status=$(_cu_status "done")
  cu_api PUT "/task/$id" "$(jq -nc --arg s "$status" '{status:$s}')" >/dev/null
}
