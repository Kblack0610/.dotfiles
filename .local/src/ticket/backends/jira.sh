#!/usr/bin/env bash
# jira backend — Jira Cloud REST v3.
#
# Config (project-map.json trackers.<project>):
#   { "system":"jira", "instance":"yoursite.atlassian.net",
#     "projectKey":"HLX", "issueType":"Task",
#     "tokenEnv":"JIRA_API_TOKEN", "emailEnv":"JIRA_EMAIL",
#     "epicMap":  { "ci":"HLX-100", ... },          # shorthand -> epic issue key
#     "labelMap": { "in-dev":"21","blocked":"31","done":"41" } }  # state -> transition id
#
# state labels (in-dev/blocked/done/todo) map to workflow TRANSITION ids via
# labelMap; area/priority labels become plain Jira labels (strings).
# pr-line: `Ticket: Jira <KEY>`.
#
# VERIFY LIVE: request shapes are dry-run-verified; exercise against a real
# Jira sandbox before trusting writes (transition ids are workflow-specific).

_jira_base()  { local h; h=$(cfg '.instance'); echo "https://$h/rest/api/3"; }
_jira_auth() {
  local email token env_email
  env_email=$(cfg '.emailEnv'); email="${!env_email:-${JIRA_EMAIL:-}}"
  token=$(resolve_token JIRA_API_TOKEN ATLASSIAN_API_TOKEN) \
    || die "no token: set tracker.tokenEnv (or JIRA_API_TOKEN)"
  [[ -n "$email" ]] || die "no email: set tracker.emailEnv (or JIRA_EMAIL)"
  printf '%s' "$(printf '%s:%s' "$email" "$token" | base64 -w0 2>/dev/null || printf '%s:%s' "$email" "$token" | base64)"
}

# jira_api METHOD PATH [body]
jira_api() {
  local method="$1" path="$2" body="${3:-}" base auth
  base=$(_jira_base); auth=$(_jira_auth)
  http "$method" "$base$path" "$body" \
    -H "Authorization: Basic $auth" -H "Content-Type: application/json" -H "Accept: application/json"
}

tb_pr_line() { echo "Ticket: Jira ${1:?key}"; }

tb_resolve_epic() {
  local area="${1:?usage: resolve-epic <shorthand>}" key
  key=$(cfg ".epicMap[\"$area\"]")
  [[ -n "$key" ]] || die "no epic mapping for '$area' (add trackers.<project>.epicMap)"
  echo "$key"
}

# Apply a state transition by abstract name (in-dev|blocked|done|todo).
_jira_transition() {
  local key="$1" state="$2" tid
  tid=$(cfg ".labelMap[\"$state\"]")
  if [[ -z "$tid" ]]; then
    # Discover by matching transition name against the abstract state.
    tid=$(jira_api GET "/issue/$key/transitions" \
      | jq -r --arg s "$state" '.transitions[] | select((.name|ascii_downcase)|test($s)) | .id' | head -1)
  fi
  [[ -n "$tid" && "$tid" != "null" ]] || { warn "no '$state' transition for $key (skipping)"; return 0; }
  jira_api POST "/issue/$key/transitions" "{\"transition\":{\"id\":\"$tid\"}}" >/dev/null
}

tb_claim() {
  local key="${1:?usage: claim <issue-key>}"
  _jira_transition "$key" "in-dev"
  tb_pr_line "$key"
}

tb_create() {
  local epic="${1:?usage: create <epic-key> <title> [--labels=..]}" title="${2:?title required}" labels_arg="${3:-}"
  local itype labels_json='[]'
  itype=$(cfg '.issueType' 'Task')

  if [[ "$labels_arg" == --labels=* ]]; then
    local lcsv="${labels_arg#--labels=}" raw lname
    local arr=()
    IFS=',' read -ra parts <<< "$lcsv"
    for raw in "${parts[@]}"; do
      lname="${raw#area:}"; lname="${lname#priority:}"; lname="${lname#state:}"
      # state names drive a post-create transition, not a label
      case "$lname" in in-dev|blocked|done|todo) continue ;; esac
      arr+=("$lname")
    done
    labels_json=$(printf '%s\n' "${arr[@]:-}" | jq -R . | jq -sc 'map(select(length>0))')
  fi

  local pkey body resp key
  pkey=$(cfg '.projectKey'); [[ -n "$pkey" ]] || die "tracker config missing .projectKey"
  body=$(jq -nc --arg p "$pkey" --arg s "$title" --arg t "$itype" --arg e "$epic" --argjson labels "$labels_json" \
    '{fields:{project:{key:$p},summary:$s,issuetype:{name:$t},parent:{key:$e},labels:$labels}}')
  resp=$(jira_api POST "/issue" "$body")
  key=$(printf '%s' "$resp" | jq -r '.key')
  [[ -n "$key" && "$key" != "null" ]] || die "issue creation failed: $resp"

  _jira_transition "$key" "in-dev"
  tb_pr_line "$key"
}

tb_done() { local key="${1:?usage: done <issue-key>}"; _jira_transition "$key" "done"; }
