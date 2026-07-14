#!/bin/bash
# SF Symbols glyphs. These are real Unicode codepoints from SF Symbols 6+.
# Bar uses SF Pro font, which renders these natively on macOS.

export ICON_APPLE=""
export ICON_CLOCK=""
export ICON_CALENDAR=""

# Battery
export ICON_BATTERY_100=""
export ICON_BATTERY_75=""
export ICON_BATTERY_50=""
export ICON_BATTERY_25=""
export ICON_BATTERY_0=""
export ICON_BATTERY_CHARGING=""

# Volume
export ICON_VOLUME_100=""
export ICON_VOLUME_66=""
export ICON_VOLUME_33=""
export ICON_VOLUME_10=""
export ICON_VOLUME_0=""
export ICON_VOLUME_MUTE=""

export ICON_CPU=""

# Fleet-pulse status dot (filled circle, colored by plugins/fleet.sh)
export ICON_FLEET="●"

# Headphones (Nerd Font U+F025) — rendered with an icon.font override on the bose_audio item,
# since SF Pro doesn't carry this glyph. Built from octal bytes so it's deterministic in bash 3.2.
export ICON_BOSE=$(printf '\357\200\245')
