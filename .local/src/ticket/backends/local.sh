#!/usr/bin/env bash
# local backend — offline ".agent todo list" tracker.
#
# Records tickets as checkbox lines in ~/.agent/todos/<project>.md instead of
# hitting any external system. Good for repos with no remote board, air-gapped
# work, or as a low-friction default. No token, no network.
#
# Config (project-map.json trackers.<project>):
#   { "system":"local" }                  # that's it; instance optional override
# id = epoch seconds. pr-line: `Ticket: local#<id>`.

_local_file() {
  local dir base
  dir=$(cfg '.instance' "$HOME/.agent/todos")
  base="${TICKET_PROJECT:-misc}"
  mkdir -p "$dir"
  echo "$dir/$base.md"
}

tb_pr_line() { echo "Ticket: local#${1:?id}"; }

# Epics are just headings here; echo the shorthand back as the "id".
tb_resolve_epic() { echo "${1:?usage: resolve-epic <shorthand>}"; }

tb_create() {
  local epic="${1:?usage: create <epic> <title> [--labels=..]}" title="${2:?title required}" labels_arg="${3:-}"
  local file id labels=""
  file=$(_local_file)
  id=$(date +%s)
  [[ "$labels_arg" == --labels=* ]] && labels=" \`${labels_arg#--labels=}\`"
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] append to $file under '## $epic': - [ ] [#$id] $title$labels" >&2
  else
    grep -q "^## $epic\$" "$file" 2>/dev/null || printf '\n## %s\n' "$epic" >> "$file"
    printf -- '- [ ] [#%s] %s%s\n' "$id" "$title" "$labels" >> "$file"
  fi
  tb_pr_line "$id"
}

# claim/done flip the checkbox state for [#id] lines, best-effort.
_local_mark() {
  local id="$1" mark="$2" file
  file=$(_local_file)
  [[ -f "$file" ]] || return 0
  if [[ "${DRY_RUN:-0}" == "1" ]]; then
    echo "[dry-run] mark [#$id] as '$mark' in $file" >&2; return 0
  fi
  sed -i "s/- \[.\] \[#$id\]/- [$mark] [#$id]/" "$file"
}

tb_claim() { local id="${1:?usage: claim <id>}"; _local_mark "$id" "~"; tb_pr_line "$id"; }
tb_done()  { local id="${1:?usage: done <id>}";  _local_mark "$id" "x"; }
