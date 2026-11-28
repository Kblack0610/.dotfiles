#!/usr/bin/env bash
# Waybar module: the machine mode chip (custom/machine-mode), right of the disk chip on the desktop
# bar. Every mode shows its initial (R, S, O, F), so the mode is always readable at a glance; it is
# neutral because a mode is the human's choice, not a health state.
# The hover is `machine-mode` as it prints. Empty when machine-mode cannot run.

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
emit "$ICON $initial" "$tip" ok
