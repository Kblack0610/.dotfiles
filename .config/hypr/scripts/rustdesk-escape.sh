#!/usr/bin/env bash
# rustdesk-escape.sh — one-way escape from the RustDesk remote session back to
# the last real local window.
#
# Why this exists: RustDesk keeps Wayland keyboard focus even when the pointer
# leaves its window (follow_mouse only re-focuses when the cursor lands ON another
# window, not on empty space / an empty monitor). This binds a single key that
# deterministically reclaims local keyboard focus. It is a NO-OP unless RustDesk
# is currently focused, so the same key can never pull you *into* the session.
set -euo pipefail

active_class=$(hyprctl activewindow -j | jq -r '.class // empty')
[ "$active_class" = "rustdesk" ] || exit 0

# Most-recently-used non-RustDesk window = lowest focusHistoryID that isn't rustdesk.
target=$(hyprctl clients -j | jq -r '
  [ .[] | select(.class != "rustdesk") ] | sort_by(.focusHistoryID) | .[0].address // empty')

if [ -n "$target" ]; then
  hyprctl dispatch focuswindow "address:$target"
else
  # No other window anywhere — fall back to a known-empty home workspace.
  hyprctl dispatch workspace 1
fi
