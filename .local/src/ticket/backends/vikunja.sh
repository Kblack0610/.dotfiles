#!/usr/bin/env bash
# vikunja backend — reference implementation of the tracker contract.
# Ported from bnb/platform scripts/vikunja-pr.sh, but reads instance / epic /
# label / bucket ids from TICKET_CFG so it works against any Vikunja instance.
#
# pr-line emits the legacy `Vikunja: <id>` so the existing bnb/platform CI
# (vikunja-pr-gate.yml / vikunja-close-on-merge.yml) keeps matching untouched.

_vk_base()  { cfg '.instance' 'https://vikunja.kblab.me/api/v1'; }
_vk_token() { resolve_token VIKUNJA_API_TOKEN VIKUNJA_MCP_TOKEN \
                || die "no token: set the env named in tracker.tokenEnv (or VIKUNJA_API_TOKEN/VIKUNJA_MCP_TOKEN)"; }

# vk_api METHOD PATH [body]
vk_api() {
  local method="$1" path="$2" body="${3:-}" base token
  base=$(_vk_base); token=$(_vk_token)
  http "$method" "$base$path" "$body" \
    -H "Authorization: Bearer $token" -H "Content-Type: application/json"
}

# Built-in global label-id defaults (vikunja.kblab.me); config.labelMap wins.
_vk_default_label() {
  case "$1" in
    "In Development"|"in development"|in-dev) echo 1 ;;
    Blocked|blocked)   echo 2 ;;
    Done|done)         echo 3 ;;
    web)        echo 5 ;; api) echo 6 ;; mobile) echo 7 ;; infra) echo 8 ;;
    ci) echo 9 ;; security) echo 10 ;; compliance) echo 11 ;;
    P0) echo 12 ;; P1) echo 13 ;; P2) echo 14 ;; P3) echo 15 ;;
    Todo|To-Do|todo)   echo 16 ;;
    *) echo "" ;;
  esac
}

# Map an abstract label name → numeric id (config.labelMap first, then default).
vk_label_id() {
  local name="$1" id
  id=$(cfg ".labelMap[\"$name\"]")
  [[ -n "$id" ]] && { echo "$id"; return 0; }
  _vk_default_label "$name"
}

# Resolve a kanban view + Doing/Done bucket id for a project.
# Sets globals VIEW_ID and BUCKET_ID. $1=pid $2=bucket-title (Doing|Done)
vk_discover_bucket() {
  local pid="$1" want="${2:-Doing}" kanban
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    vk_api GET "/projects/$pid/views" >/dev/null   # show the intended read
    VIEW_ID="<view>"; BUCKET_ID="<$want-bucket>"; return 0
  fi
  kanban=$(vk_api GET "/projects/$pid/views" \
    | jq '[.[] | select(.view_kind=="kanban")] | .[0]')
  VIEW_ID=$(printf '%s' "$kanban" | jq -r '.id')
  [[ -n "$VIEW_ID" && "$VIEW_ID" != "null" ]] || die "no kanban view on project $pid"
  BUCKET_ID=$(vk_api GET "/projects/$pid/views/$VIEW_ID/buckets" \
    | jq -r --arg w "$want" '.[] | select(.title==$w) | .id' | head -1)
  [[ -n "$BUCKET_ID" && "$BUCKET_ID" != "null" ]] || die "no '$want' bucket on project $pid view $VIEW_ID"
}

# --- contract -----------------------------------------------------------------

tb_pr_line() { local id="${1:?id}"; echo "Vikunja: $id"; }

tb_resolve_epic() {
  local area="${1:?usage: resolve-epic <shorthand>}" id
  id=$(cfg ".epicMap[\"$area\"]")
  [[ -n "$id" ]] && { echo "$id"; return 0; }
  # Built-in fallback (bnb/platform epics under project 9).
  case "$area" in
    ci) echo 24 ;; mobile-ci) echo 25 ;; mobile) echo 22 ;;
    backups|dr|backup) echo 26 ;; compliance|security|hipaa) echo 27 ;;
    preview|home-k3s) echo 28 ;; release) echo 29 ;;
    *) die "no epic mapping for '$area' (add it to trackers.<project>.epicMap)" ;;
  esac
}

tb_claim() {
  local id="${1:?usage: claim <task-id>}" task pid
  task=$(vk_api GET "/tasks/$id")
  pid=$(printf '%s' "$task" | jq -r '.project_id')
  if [[ -z "$pid" || "$pid" == "null" ]]; then
    [[ "${DRY_RUN:-0}" == "1" ]] && pid="<pid>" || die "task $id has no project"
  fi

  local todo indev
  todo=$(vk_label_id Todo); indev=$(vk_label_id "In Development")
  [[ -n "$todo"  ]] && vk_api DELETE "/tasks/$id/labels/$todo"  >/dev/null 2>&1 || true
  [[ -n "$indev" ]] && vk_api PUT "/tasks/$id/labels" "{\"label_id\": $indev}" >/dev/null

  vk_discover_bucket "$pid" Doing
  vk_api POST "/projects/$pid/views/$VIEW_ID/buckets/$BUCKET_ID/tasks" \
    "{\"task_id\": $id}" >/dev/null

  tb_pr_line "$id"
}

tb_create() {
  local pid="${1:?usage: create <epic> <title> [--labels=..]}" title="${2:?title required}" labels_arg="${3:-}"
  local resp tid body
  body=$(jq -nc --arg t "$title" '{title: $t}')
  resp=$(vk_api PUT "/projects/$pid/tasks" "$body")
  tid=$(printf '%s' "$resp" | jq -r '.id')
  [[ -n "$tid" && "$tid" != "null" ]] || die "task creation failed"

  if [[ "$labels_arg" == --labels=* ]]; then
    local lcsv="${labels_arg#--labels=}" raw lname lid
    IFS=',' read -ra parts <<< "$lcsv"
    for raw in "${parts[@]}"; do
      lname="${raw#area:}"; lname="${lname#priority:}"; lname="${lname#state:}"
      lid=$(vk_label_id "$lname")
      [[ -z "$lid" ]] && { warn "unknown label '$raw' (skipping)"; continue; }
      vk_api PUT "/tasks/$tid/labels" "{\"label_id\": $lid}" >/dev/null
    done
  fi

  vk_discover_bucket "$pid" Doing
  vk_api POST "/projects/$pid/views/$VIEW_ID/buckets/$BUCKET_ID/tasks" \
    "{\"task_id\": $tid}" >/dev/null

  tb_pr_line "$tid"
}

tb_done() {
  local id="${1:?usage: done <task-id>}" task pid done_id
  vk_api POST "/tasks/$id" '{"done": true}' >/dev/null
  done_id=$(vk_label_id Done)
  [[ -n "$done_id" ]] && vk_api PUT "/tasks/$id/labels" "{\"label_id\": $done_id}" >/dev/null 2>&1 || true
  task=$(vk_api GET "/tasks/$id"); pid=$(printf '%s' "$task" | jq -r '.project_id')
  if [[ -n "$pid" && "$pid" != "null" ]]; then
    vk_discover_bucket "$pid" Done 2>/dev/null \
      && vk_api POST "/projects/$pid/views/$VIEW_ID/buckets/$BUCKET_ID/tasks" "{\"task_id\": $id}" >/dev/null 2>&1 || true
  fi
}
