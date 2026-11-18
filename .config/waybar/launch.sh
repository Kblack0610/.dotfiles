#!/usr/bin/env sh
# Pick waybar config by battery presence, and the stylesheet by the part desk runs
# (waybar-classic or waybar-modern; docs/desk.md).
# Portable across machines: any laptop with BAT0/BAT1 gets the laptop profile.
set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    PROFILE="laptop"
else
    PROFILE="desktop"
fi

# waybar-modern is the same bar with style-modern.css layered on the theme's style.css.
STYLE=style.css
[ "$("$HOME/.local/bin/desk" get bar 2>/dev/null || true)" = waybar-modern ] && STYLE=style-modern.css

# WAYBAR_BIN: tests point it at a stub, so they never start a real bar.
exec "${WAYBAR_BIN:-/usr/bin/waybar}" -c "$CONFIG_DIR/config.$PROFILE" -s "$CONFIG_DIR/$STYLE"
