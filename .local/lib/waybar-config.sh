# shellcheck shell=bash
# waybar_config_json <waybar-dir>: the waybar config as one JSON object of module
# definitions, for the readers outside waybar (control-menu, and `desk chip`, which feeds
# the Noctalia bar). The files are JSONC; every comment in them is a whole line, so
# dropping those lines leaves JSON (a URL's // survives). control_menu.bats parses the
# real files, so a comment added mid-line fails there first.
waybar_config_json() {
    local f
    for f in "$1/config.base" "$1/config.pin-full"; do
        # if, not &&: a missing last file must not fail the loop under pipefail.
        if [ -r "$f" ]; then sed '/^[[:space:]]*\/\//d' "$f"; fi
    done | jq -s 'map(if type == "array" then add else . end) | add'
}
