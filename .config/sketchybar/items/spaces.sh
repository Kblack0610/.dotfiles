#!/bin/bash
# AeroSpace workspace indicators. The workspace list matches aerospace.toml (1..9).
# Clicking a workspace switches to it. Active workspace gets a highlighted bg.

WORKSPACES=(1 2 3 4 5 6 7 8 9)

for sid in "${WORKSPACES[@]}"; do
  sketchybar --add item space.$sid left \
             --subscribe space.$sid aerospace_workspace_change front_app_switched \
             --set space.$sid \
                   updates=on \
                   icon="$sid" \
                   icon.font="SF Pro:Bold:13.0" \
                   icon.padding_left=10 \
                   icon.padding_right=10 \
                   icon.color="$WHITE" \
                   label.drawing=off \
                   background.drawing=on \
                   background.color=0x00000000 \
                   background.corner_radius=6 \
                   background.height=22 \
                   click_script="aerospace workspace $sid" \
                   script="$CONFIG_DIR/plugins/aerospace.sh $sid"
done

# Trigger an initial render so the active workspace highlights on bar startup,
# even before the first workspace switch.
FOCUSED=$(aerospace list-workspaces --focused 2>/dev/null || echo 1)
sketchybar --trigger aerospace_workspace_change FOCUSED_WORKSPACE="$FOCUSED"
