#!/usr/bin/env bash
# rustdesk-grab-toggle.sh — flip whether apps may grab ALL keyboard shortcuts via
# the Wayland keyboard-shortcuts-inhibit protocol (RustDesk uses this, like Moonlight).
#
#   GRAB OFF (default): the compositor keeps its keybinds; RustDesk is just a window.
#                       Super-combos drive Hyprland, NOT the remote.
#   GRAB ON           : every key (including Super) forwards to the remote Mac, for
#                       full remote control / Mac shortcuts.
#
# Hyprland reads binds:disable_keybind_grabbing live on every keypress, so the flip is
# instant. The Ctrl+Alt+Shift+Esc escape is a `bindp` (dontInhibit) bind, so it ALWAYS
# fires even in GRAB ON mode — you can never get trapped in the remote session.
set -euo pipefail

note() { hyprctl notify -1 2500 "rgb(88c0d0)" "$1"; }

# int=1 means grabbing is currently DISABLED (compositor control / GRAB OFF).
cur=$(hyprctl getoption binds:disable_keybind_grabbing -j | jq -r '.int')

if [ "$cur" = "1" ]; then
  hyprctl keyword binds:disable_keybind_grabbing false
  note "RustDesk: FULL passthrough → all keys go to the Mac. Ctrl+Alt+Shift+Esc to step out."
else
  hyprctl keyword binds:disable_keybind_grabbing true
  note "RustDesk: compositor control → your Hyprland keybinds work locally."
fi
