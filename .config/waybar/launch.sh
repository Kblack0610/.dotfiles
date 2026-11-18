#!/usr/bin/env sh
# Pick waybar config by battery presence, and the layout by the part desk runs
# (waybar-classic or waybar-modern; docs/desk.md).
# Portable across machines: any laptop with BAT0/BAT1 gets the laptop profile.
set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    PROFILE="laptop"
else
    PROFILE="desktop"
fi

# layout.css is generated (gitignored): every theme template @imports it, so it
# carries the layout whichever theme is active. Modern adds its palette colours and
# its overrides on top of the classic rules.
part="$("$HOME/.local/bin/desk" get bar 2>/dev/null || echo waybar-classic)"
case "$part" in
    waybar-modern)
        printf '@import url("layout-classic.css");\n@import url("palette.css");\n@import url("layout-modern.css");\n' ;;
    *)
        printf '@import url("layout-classic.css");\n' ;;
esac > "$CONFIG_DIR/layout.css"

# WAYBAR_BIN: tests point it at a stub, so they never start a real bar.
exec "${WAYBAR_BIN:-/usr/bin/waybar}" -c "$CONFIG_DIR/config.$PROFILE" -s "$CONFIG_DIR/style.css"
