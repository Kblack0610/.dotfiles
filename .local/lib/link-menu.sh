# link-menu.sh: the desktop note and the fuzzy wofi/rofi picker of the link launchers
# (karakeep-menu, kblab-menu). Set MENU_TITLE (the note's title) and MENU_WIDTH (wofi's width)
# before sourcing it.

# notify <message>: a desktop note; a box with no notify-send shows nothing.
notify() { command -v notify-send >/dev/null && notify-send "$MENU_TITLE" "$1"; }

# menu <prompt>: the picked line of stdin on stdout; fails when cancelled or with no picker.
menu() {
    if command -v wofi >/dev/null 2>&1; then
        wofi --dmenu -i --matching=fuzzy -p "$1" --width "$MENU_WIDTH" --height 600
    elif command -v rofi >/dev/null 2>&1; then
        rofi -dmenu -i -matching fuzzy -p "$1"
    else
        return 1
    fi
}
