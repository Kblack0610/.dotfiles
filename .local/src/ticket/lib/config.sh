#!/usr/bin/env bash
# config.sh — resolve which tracker backend + config apply to the current repo.
#
# Resolution (first match wins) sets two globals:
#   TICKET_SYSTEM  — backend name (vikunja|jira|clickup|linear|notion)
#   TICKET_CFG     — the raw JSON config object for that tracker
#
# Sources, in order:
#   1. project-map.json  trackers.<project-name>   (project resolved by repo path)
#   2. project-map.json  trackers.default
#   (Repo-local scripts/ticket.sh override is handled earlier, in the entrypoint.)

MAP_FILE="${PROJECT_MAP_FILE:-$HOME/.dotfiles/.config/shared-hooks/project-map.json}"
NAME_LIB="${PROJECT_NAME_LIB:-$HOME/.dotfiles/.config/shared-hooks/project-name.sh}"

# Resolve the canonical project name for a directory, reusing the shared-hooks
# single source of truth when present (falls back to basename otherwise).
_project_name() {
  local dir="$1"
  if [[ -f "$NAME_LIB" ]]; then
    # shellcheck source=/dev/null
    . "$NAME_LIB"
    resolve_project_name "$dir"
  else
    local base="${dir##*/}"; echo "${base#.}"
  fi
}

# Walk up from $PWD to find the repo root (git toplevel), else use $PWD.
_repo_root() {
  git rev-parse --show-toplevel 2>/dev/null || pwd
}

load_tracker_config() {
  local root name obj
  root=$(_repo_root)
  name=$(_project_name "$root")

  command -v jq >/dev/null 2>&1 || die "jq is required"
  [[ -f "$MAP_FILE" ]] || die "no project map at $MAP_FILE"

  # Per-project, then default.
  obj=$(jq -c --arg n "$name" '.trackers[$n] // empty' "$MAP_FILE" 2>/dev/null)
  if [[ -z "$obj" ]]; then
    obj=$(jq -c '.trackers.default // empty' "$MAP_FILE" 2>/dev/null)
  fi
  [[ -n "$obj" ]] || die "no tracker configured for project '$name' (add trackers.$name or trackers.default to project-map.json)"

  TICKET_CFG="$obj"
  TICKET_PROJECT="$name"
  TICKET_SYSTEM=$(printf '%s' "$obj" | jq -r '.system // empty')
  [[ -n "$TICKET_SYSTEM" ]] || die "tracker config for '$name' has no .system"
  export TICKET_CFG TICKET_PROJECT TICKET_SYSTEM
}
