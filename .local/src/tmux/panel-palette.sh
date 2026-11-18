# shellcheck shell=bash
# shellcheck disable=SC2034
#
# panel-palette.sh - the colour and glyph names every panel surface shares, SOURCED (never
# executed) by panel-lib.sh and by agent-ask, whose cards the questions panel shows. It sets
# variables only: no `set` options, no PATH change, no $SELF needed, so a script that is not a
# panel can take the palette without taking the library.
#
# The C_* names and the $'..' form, taken from fleet.sh and the retired task cockpit (the
# two largest surfaces at the time, so they won on volume and recency).
#
# The $'..' form is load-bearing, not cosmetic: pr-viewer.sh's single-quoted '\033[..'
# requires printf %b, so the first person to reach for %s silently prints a literal \033.
#
# HARD RULE: ANSI indices 0-7 and 90, plus SGR attributes. NEVER 38;2;R;G;B (truecolor) and
# never 38;5;N (256-colour). This is exactly what makes these surfaces theme-responsive
# TODAY: theme-switch recolours the TERMINAL's palette, so \033[1;32m follows a theme swap
# for free. Pinning a hex value would stop the surface tracking the terminal -- a regression
# dressed as a feature. tests/integ/panel_conformance.bats enforces it.
if [ -n "${PANEL_NO_COLOR:-${NO_COLOR:-}}" ]; then
  C_HEAD='' C_SEL='' C_INP='' C_ERR='' C_DIM='' C_BOX='' C_PROJ='' C_ACC='' C_BOLD='' C_FAINT='' C_OFF=''
else
  C_HEAD=$'\033[1;37m' # section header (bold white)
  C_SEL=$'\033[1;32m'  # healthy / active / selected (bold green)
  C_INP=$'\033[1;33m'  # in-progress / needs attention (yellow)
  C_ERR=$'\033[1;31m'  # failed / tripped (bold red)
  C_DIM=$'\033[90m'    # dim
  C_BOX=$'\033[36m'    # checkbox / accent (cyan)
  C_PROJ=$'\033[1;35m' # project sub-header (magenta)
  C_ACC=$'\033[1;34m'  # blue accent
  # Attributes with no colour: on fzf's selected row they take its fg+ white, so they still
  # read on the selection bar (colour 8, the same grey as C_DIM, which vanishes there).
  C_BOLD=$'\033[1m'
  C_FAINT=$'\033[2m'
  C_OFF=$'\033[0m'
fi

# Glyph vocabulary, shared with claude-status.sh and agent-panel/src/fzf.rs so every surface
# reports agent state the same way: ! needs you · ~ working · ✓ healthy · · idle
G_ATTN='!'
G_BUSY='~'
G_OK='✓'
G_IDLE='·'
