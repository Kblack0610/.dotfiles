#!/bin/bash
# Bose audio claim indicator (visible, clickable). One job: show whether the Mac currently
# "owns" the Bose QC35 II, and toggle it on click.
#   GREEN headphones = claimed  (output + mic routed to the Bose, for a meeting/Slack call)
#   DIM   headphones = guarding (the bose-audio daemon keeps output off the Bose so a phone
#                                keeps the headphones)
# State is driven by `bose-audio status`; the bose-audio CLI fires `--trigger bose_audio` on
# every grab/release so this repaints instantly. Click runs `bose-audio toggle`.
# Icon uses a Nerd Font override (SF Pro lacks the headphones glyph) — see icons.sh ICON_BOSE.
sketchybar --add event bose_audio 2>/dev/null
sketchybar --add item bose_audio right \
           --set bose_audio \
                 icon="$ICON_BOSE" \
                 icon.font="Symbols Nerd Font:Regular:16.0" \
                 icon.color="$DIM" \
                 label.drawing=off \
                 updates=on \
                 script="$CONFIG_DIR/plugins/bose_audio.sh" \
                 click_script="$HOME/.local/bin/bose-audio toggle" \
           --subscribe bose_audio bose_audio system_woke
