#!/usr/bin/env bash
# Turn waybar custom modules on/off at runtime, no restart. Driven from the pin
# leader menu (Super+A -> s settings) or straight from a shell. See PIN.md.
#
#   modules.sh gate <module-id> <cmd> [args...]  wrapper the configs call
#   modules.sh list                              every module and its state
#   modules.sh on|off|toggle <key>               flip one module (or group)
#   modules.sh menu                              interactive picker (needs fzf)
#
# Waybar disables a custom module whose exec prints nothing (`hide-empty-text`
# in man waybar-custom). `gate` wraps each module's real exec and prints nothing
# while the module is off, so the bar drops it - no config rewrite, no restart.
# A toggle then fires SIGRTMIN+10, which every gated module re-runs on, so the
# change lands instantly instead of waiting out that module's interval.
#
# State: ~/.local/state/waybar/modules.off, one disabled module id per line.
# Absent or empty = everything on. Machine-local on purpose (the desktop and the
# laptop want different answers), and it outlives a reboot unlike pin.sh's
# /tmp state.

set -u

CONF_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"
REGISTRY="$CONF_DIR/modules.registry"
STATE_DIR="${XDG_STATE_HOME:-$HOME/.local/state}/waybar"
OFF="$STATE_DIR/modules.off"
SIGNAL=10
NOTIFY_ID=990012

# --- gate ---------------------------------------------------------------------
# The hot path: waybar runs this once per module every couple of seconds, so it
# stays ahead of everything else in the file and never reads the registry.
if [[ "${1:-}" == "gate" ]]; then
    mod="${2:?gate needs a module id}"
    shift 2
    grep -qxF -- "$mod" "$OFF" 2>/dev/null && exit 0   # empty stdout: waybar hides it
    exec "$@"
fi

# --- registry -----------------------------------------------------------------
rows() { grep -v -e '^[[:space:]]*#' -e '^[[:space:]]*$' "$REGISTRY"; }
keys() { rows | cut -d'|' -f1; }
label_of() { rows | awk -F'|' -v k="$1" '$1==k{print $2}'; }
ids_of() { rows | awk -F'|' -v k="$1" '$1==k{print $3}' | tr ' ' '\n' | grep -v '^$'; }

require_key() {
    keys | grep -qxF -- "$1" && return 0
    echo "unknown module: $1 (try: $(keys | tr '\n' ' '))" >&2
    exit 2
}

# A key counts as off only when every id it owns is off, so a half-written state
# file reads as on and the next toggle rewrites it whole.
is_off() {
    local id
    for id in $(ids_of "$1"); do
        grep -qxF -- "$id" "$OFF" 2>/dev/null || return 1
    done
    return 0
}

# --- state --------------------------------------------------------------------
current() { cat "$OFF" 2>/dev/null || true; }

commit() {  # stdin: the new disabled list
    mkdir -p "$STATE_DIR"
    grep -v '^[[:space:]]*$' | sort -u > "$OFF.tmp" || true
    mv "$OFF.tmp" "$OFF"
}

# grep -F reads a newline-separated $ids as one pattern per line.
disable() { { current; ids_of "$1"; } | commit; }
enable()  { current | { grep -vxF -- "$(ids_of "$1")" || true; } | commit; }

refresh() {
    # Match on process name only. Never `pkill -f`: this script's own path
    # contains "waybar", so -f would have it signal itself.
    pkill -RTMIN+$SIGNAL waybar 2>/dev/null || true
}

notify() {
    command -v dunstify >/dev/null 2>&1 \
        && dunstify -r "$NOTIFY_ID" -t 2000 -u low "waybar" "$1" >/dev/null 2>&1 \
        || true
}

set_state() {  # set_state <key> <on|off>
    require_key "$1"
    if [[ "$2" == off ]]; then disable "$1"; else enable "$1"; fi
    refresh
    notify "$(label_of "$1") $2"
}

toggle() {
    require_key "$1"
    if is_off "$1"; then set_state "$1" on; else set_state "$1" off; fi
}

# --- ui -----------------------------------------------------------------------
render() {
    local k mark
    for k in $(keys); do
        if is_off "$k"; then mark='[ ]'; else mark='[x]'; fi
        printf '%s %-9s %s\n' "$mark" "$k" "$(label_of "$k")"
    done
}

menu() {
    command -v fzf >/dev/null 2>&1 || { echo "menu needs fzf" >&2; exit 2; }
    local sel key
    while true; do
        sel=$(render | fzf --no-sort --height=100% \
                --prompt='waybar modules> ' \
                --header='enter toggles - esc quits') || break
        key=$(awk '{print $2}' <<< "$sel")
        [[ -n "$key" ]] && toggle "$key"
    done
}

case "${1:-list}" in
    list)   render ;;
    menu)   menu ;;
    on)     set_state "${2:?usage: modules.sh on <key>}" on ;;
    off)    set_state "${2:?usage: modules.sh off <key>}" off ;;
    toggle) toggle "${2:?usage: modules.sh toggle <key>}" ;;
    *)      echo "usage: modules.sh {gate|list|menu|on|off|toggle} [args]" >&2; exit 2 ;;
esac
