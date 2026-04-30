#!/usr/bin/env sh
# Pick waybar config by battery presence.
# Portable across machines: any laptop with BAT0/BAT1 gets the laptop profile.
set -eu

CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/waybar"

if [ -d /sys/class/power_supply/BAT0 ] || [ -d /sys/class/power_supply/BAT1 ]; then
    PROFILE="laptop"
else
    PROFILE="desktop"
fi

exec /usr/bin/waybar -c "$CONFIG_DIR/config.$PROFILE" -s "$CONFIG_DIR/style.css"
