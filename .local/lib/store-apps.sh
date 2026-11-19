# shellcheck shell=bash
# store-apps.sh - the store apps of every product, from project-map.json.
#
#   . store-apps.sh
#   store_apps    one {project, store, app} per line, each app once per product
#
# Each product's store targets (`trackers.<p>.targets[].live`: steam.app, play.package,
# testflight.app), the list release-state probes. store-reviews and store-sales read their
# stores for exactly these apps. A product not visible on this machine's profile is left out.
PROJECT_NAME_LIB="${PROJECT_NAME_LIB:-$(dirname "$(realpath "${BASH_SOURCE[0]}")")/../../.config/shared-hooks/project-name.sh}"
# shellcheck source=../../.config/shared-hooks/project-name.sh
. "$PROJECT_NAME_LIB"

store_apps() {
  local map
  map="$(project_map_file)"
  [ -f "$map" ] || { echo "no registry at $map" >&2; return 1; }
  project_machine_profile >/dev/null
  jq -c --arg m "$PROJECT_MACHINE_PROFILE" --slurpfile reg "$map" "$PROJECT_VISIBLE_JQ"'
    [(.trackers // {}) | to_entries[]
     | select(.value | type == "object") | .key as $p | select($p | visible($m))
     | (.value.targets // [])[] | objects | .live // {}
     | ({project: $p, store: "steam", app: .steam.app},
        {project: $p, store: "play", app: .play.package},
        {project: $p, store: "app_store", app: .testflight.app})
     | select(.app != null) | .app |= tostring] | unique[]' "$map"
}
