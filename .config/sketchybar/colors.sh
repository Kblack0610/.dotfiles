#!/bin/bash
# Color palette ported from waybar style.css (Jackie Brown theme)
# Format is 0xAARRGGBB — 0xff = fully opaque, 0xcc ≈ 80%, 0x66 ≈ 40%

# Bar background
export BAR_COLOR=0xe62c1c15        # rgba(44,28,21,0.9)
export BAR_BORDER_COLOR=0x4daee0c8 # rgba(174,140,32,0.3)

# Item backgrounds
export ITEM_BG_COLOR=0x663d2a1e    # rgba(61,42,30,0.4)
export ACCENT_BG_COLOR=0x33ae8c20  # rgba(174,140,32,0.2)
export ACTIVE_BG_COLOR=0x4dffcc2f  # rgba(255,204,47,0.3)

# Foreground / accents
export WHITE=0xffbfbfbf
export DIM=0xff666666
export GOLD=0xffffcc2f
export GREEN=0xff86a83e
export RED=0xffef5734
export BLUE=0xff246db2
export CYAN=0xff00acee
export MAGENTA=0xffcf5ec0
export YELLOW=0xffbdbe00

# Semantic
export CLOCK_COLOR=$GOLD
export BATTERY_COLOR=$GREEN
export BATTERY_LOW_COLOR=$RED
export VOLUME_COLOR=$MAGENTA
export CPU_COLOR=$BLUE
