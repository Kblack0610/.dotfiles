#!/usr/bin/env bash
# Waybar module: caffeine, the keep-awake chip. A click holds idle off with one detached
# `systemd-inhibit --what=idle` (hypridle honours it), a second click lets it go. It replaces waybar's
# built-in idle_inhibitor so it can sit behind `modules.sh gate` like every other chip: off on one
# machine, on another, with no config fork (PIN.md, "Module toggles").
#
#   caffeine.sh          the chip JSON (waybar re-runs it after each click)
#   caffeine.sh toggle   start or stop the hold
#
# The hold's pid is in the runtime dir, so it ends with the login, and outlives a waybar restart.

set -u
PIDFILE="${XDG_RUNTIME_DIR:-/tmp}/waybar-caffeine.pid"
ON=$'\uf06e' OFF=$'\uf070'   # nerd-font eye and eye-slash, the built-in chip's icons

# The pidfile holds "<pid> <start time>": a start time is fixed at fork and survives exec, so the hold
# reads on the instant the click returns, and a pid the kernel reuses for another process never matches.
started() {
    local stat f
    { stat="$(< "/proc/$1/stat")"; } 2>/dev/null || return 1
    read -ra f <<< "${stat##*) }"
    echo "${f[19]}"   # field 22, starttime, counted from field 3
}

holding() {
    local start=""
    read -r pid start 2>/dev/null < "$PIDFILE" || return 1
    [[ "$pid" =~ ^[0-9]+$ ]] || return 1
    [[ -n "$start" && "$(started "$pid")" == "$start" ]]
}

case "${1:-}" in
    toggle)
        if holding; then
            # setsid made the hold its own process group: take the sleep down with it. On a double
            # click faster than setsid's own setsid(), the group is not there yet, so kill the pid.
            kill -- "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null
            rm -f "$PIDFILE"
        else
            setsid systemd-inhibit --what=idle --who=caffeine --why="waybar caffeine chip" \
                sleep infinity < /dev/null > /dev/null 2>&1 &
            echo "$! $(started "$!")" > "$PIDFILE"
        fi
        ;;
    "")
        if holding; then
            printf '{"text": "%s", "class": "activated", "tooltip": "Caffeine on: idle is held off. Click to let it go."}\n' "$ON"
        else
            printf '{"text": "%s", "class": "deactivated", "tooltip": "Caffeine off. Click to keep this machine awake."}\n' "$OFF"
        fi
        ;;
    *) echo "usage: caffeine.sh [toggle]" >&2; exit 2 ;;
esac
