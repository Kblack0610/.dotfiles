#!/usr/bin/env bash
# Waybar module: caffeine, the keep-awake chip. A click holds idle off with `systemd-inhibit
# --what=idle` (hypridle honours it), a second click lets it go. It replaces waybar's built-in
# idle_inhibitor so it can sit behind `modules.sh gate` like every other chip: off on one machine, on
# another, with no config fork (PIN.md, "Module toggles").
#
#   caffeine.sh          the chip JSON (waybar re-runs it after each click and every interval)
#   caffeine.sh toggle   start or stop the hold
#
# The hold is its own transient user unit, not a child of the bar: desk.service kills its whole
# cgroup on a restart or a bar switch, which would drop a child hold without a word. systemd owns the
# state, so a second start of the same unit is refused, and the user manager ends it with the login.

set -u
UNIT=waybar-caffeine
ON=$'\uf06e' OFF=$'\uf070'   # nerd-font eye and eye-slash, the built-in chip's icons

holding() { systemctl --user is-active --quiet "$UNIT"; }

case "${1:-}" in
    toggle)
        if holding; then
            systemctl --user stop "$UNIT"
        else
            systemd-run --user --quiet --collect --unit="$UNIT" \
                systemd-inhibit --what=idle --who=caffeine --why="waybar caffeine chip" sleep infinity
        fi
        # Waybar re-runs the chip after its own click; Noctalia's chip plugin does not, so redraw it now.
        "$HOME/.local/bin/desk" signal custom/caffeine 2>/dev/null || true
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
