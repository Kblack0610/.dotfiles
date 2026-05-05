#!/bin/bash
# Resolve a canonical project name from an absolute path.
# Sourced by session-preflight.sh, stop hooks, etc. Single source of truth.
#
#   . project-name.sh
#   resolve_project_name /home/kblack0610/.dotfiles   # -> dotfiles
#
# Resolution order (first match wins):
#   1. Exact path lookup in project-map.json `paths`.
#   2. basename (leading dot stripped) looked up in `aliases`.
#   3. basename (leading dot stripped) as-is.

resolve_project_name() {
  local abs_path="$1"
  local map_file="${PROJECT_MAP_FILE:-$HOME/.dotfiles/.config/shared-hooks/project-map.json}"
  local base="${abs_path##*/}"
  base="${base#.}"

  if [ -f "$map_file" ] && command -v jq >/dev/null 2>&1; then
    local hit
    hit=$(jq -r --arg p "$abs_path" '.paths[$p] // empty' "$map_file" 2>/dev/null)
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
    hit=$(jq -r --arg b "$base" '.aliases[$b] // empty' "$map_file" 2>/dev/null)
    if [ -n "$hit" ]; then echo "$hit"; return 0; fi
  fi

  echo "$base"
}
