# harness-projects.sh -- the one reader of a harness's project allowlist (harnesses.json `projects`),
# sourced by fleet-dispatch (route, gateway_launch) and fleet-bench (canary queue).
#
# A harness whose provider may train on prompts (ocfree, OpenCode's free models) carries public
# input only, so its `projects` names the public projects it may read; a harness with no `projects`
# takes every project. Why: the human kept free-endpoint training on (2026-11-11) for public input
# only, and a private or client repo must never reach those models.

# harness_project_why <map> <harness> <project> -> why the harness may not run that project's work, and
# rc 1 when its list leaves the project out; nothing and rc 0 when it may. rc 2 with the reason when the
# allowlist cannot be read: an unreadable map, a harness the map does not have, or a `projects` that is
# not a list of names. fleet-dispatch refuses on any nonzero rc (fail closed); the canary queue skips a
# task only on rc 1 and leaves the rest to that refusal.
harness_project_why() {
  local list
  list=$(jq -r --arg h "$2" '.harnesses[$h] | if type != "object" then "?" elif has("projects") | not then "*"
      elif (.projects | type) == "array" and all(.projects[]; type == "string" and . != "") then "=" + (.projects | join(","))
      else "!" end' "$1" 2>/dev/null) || list='?'
  case "$list" in
    '*') return 0 ;;
    '?') echo "its project allowlist cannot be read from $1"; return 2 ;;
    '!') echo "its projects in $1 is not a list of project names"; return 2 ;;
    '=') echo "its projects in $1 allows no project"; return 1 ;;
  esac
  [[ ",${list#=}," == *",$3,"* ]] && return 0
  echo "it takes only ${list#=} work (projects in $1), and this is ${3:-an item with no project}"
  return 1
}
