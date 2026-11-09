#!/usr/bin/env bash
# Waybar module: the machine mode chip (custom/machine-mode), right of the disk chip on the desktop
# bar. Every mode shows its initial (R, S, O, F), so the mode is always readable at a glance; it is
# neutral because a mode is the human's choice, not a health state.
# Amber in any mode when the runner part of the last switch never reached the cluster, so the mode
# is not the whole truth. The hover is `machine-mode` as it prints. Empty on a machine with no pool
# runners, such as a thin client.

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
