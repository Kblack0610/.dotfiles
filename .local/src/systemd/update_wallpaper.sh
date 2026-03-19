#!/bin/sh
# Set a random wallpaper from ~/Media/Wallpapers using hyprpaper IPC
# Requires: hyprpaper running with ipc = on

WALLPAPER_DIR="$HOME/Media/Wallpapers"

# Pick a random wallpaper
WALLPAPER=$(find "$WALLPAPER_DIR" -type f \( -name '*.jpg' -o -name '*.jpeg' -o -name '*.png' -o -name '*.webp' \) | shuf -n 1)

if [ -z "$WALLPAPER" ]; then
    echo "No wallpapers found in $WALLPAPER_DIR"
    exit 1
fi

# Unload all previously loaded wallpapers, preload new one, set it
hyprctl hyprpaper unload all
hyprctl hyprpaper preload "$WALLPAPER"
hyprctl hyprpaper wallpaper ",$WALLPAPER"

echo "Set wallpaper: $(basename "$WALLPAPER")"
