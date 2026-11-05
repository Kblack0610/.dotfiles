#!/usr/bin/env bash
# Waybar module: the machine mode chip (custom/machine-mode). The bar is the mode's initial, since
# the bar has no width to spare at 1920 and the word pushed the tray off the screen. Neutral at
# every mode because a mode is the human's choice, not a health state. Amber only when the runner
# part of the last switch never reached the cluster, so the letter is not the whole truth. The hover
# is `machine-mode` as it prints. Empty on a machine with no pool runners, such as a thin client.

set -u
here="$(dirname "$(realpath "${BASH_SOURCE[0]}")")"
# shellcheck source=pango.sh
. "$here/pango.sh"

# nf-fa-sliders, written as an escape so an editor cannot strip the glyph from this file.
ICON=$'\uf1de'

export PROM_TIMEOUT
out="$("$here/../../.local/bin/machine-mode" 2>/dev/null)" || { emit "" "" ""; exit 0; }
mode="${out%%$'\n'*}"
mode="${mode#mode: }"
initial="${mode:0:1}"
initial="${initial^^}"
tip="$(pango_esc "$out")"$'\n\n'"click: next mode"

if grep -qx 'RUNNERS_PINNED=no' "$HOME/.agent/machine-mode.env" 2>/dev/null; then
  emit "$ICON $(paint "$C_YEL" "$initial")" "$tip" warn
else
  emit "$ICON $initial" "$tip" ok
fi
