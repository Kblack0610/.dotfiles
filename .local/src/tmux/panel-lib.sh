# shellcheck shell=bash
# shellcheck disable=SC2034
#
# NOTE: the two directives above are load-bearing, and no other comment in this file may
# begin with the word after a "# " that shellcheck reserves -- it parses ANY such comment as
# a directive and errors on the ones that are really prose.
#
# There is no shebang because this file is SOURCED, never executed. The shell= directive is
# what supplies the dialect; without it SC2148 fires at ERROR severity and fails the lint
# gate. (focus-lib.sh uses a real shebang for the same purpose; a directive is the more honest
# spelling for a fragment that is not runnable.) The disable is for SC2034: the palette and
# the PANEL_* names are this library's public API, read by consumers rather than by anything
# in here, so "appears unused" is a false positive for the whole file.
#
# panel-lib.sh - the shared floor for every tmux panel surface.
#
# A "panel" is a script bound to a key in .tmux.conf and opened with `display-popup -E`.
# Eleven of them grew one at a time and every cross-cutting concern drifted apart: six
# geometries, four fzf dialects, three palette naming schemes, five ways to resolve $0, ten
# scripts with no strict mode. This file is the one floor they now stand on.
#
# SOURCE IT WITH EXACTLY TWO LINES, at the top of the script:
#
#     SELF="$(realpath "${BASH_SOURCE[0]}")"
#     . "${SELF%/*}/panel-lib.sh" || exit 1
#
# ${BASH_SOURCE[0]}, NOT $0 -- the unit tier SOURCES a subject to test its functions, and
# under `source` $0 is the bats runner, so `realpath "$0"` would resolve to the wrong file
# and the sibling lookup below would fail. ${BASH_SOURCE[0]} is right in both cases.
#
# `realpath`, not `readlink -f` -- -f is a GNU extension absent from older macOS, and this
# repo is shared with a Mac (see .config/aerospace, sketchybar, Brewfile).
#
# $SELF stays the CALLER's boilerplate rather than a function here, because there is a real
# chicken-and-egg: you cannot call panel_self() before you know where this file is. One
# honest line beats a multi-candidate probe loop.
#
# What is deliberately NOT here, and why:
#   - the test seam `[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0`. It must execute at the
#     CALLER's top-level scope; wrapped in a function, `return` only exits the function.
#     It stays copy-pasted. See CONVENTIONS.md.
#   - popup geometry. That is a .tmux.conf concern (%hidden constants), not a script one.
#   - the claude-pane -> session-id resolver. Triplicated today (favourites.sh, sessions,
#     agent-panel/src/procmap.rs) but one copy is Rust; the fix is to shell out to
#     `agent-panel list`, not to add a fourth implementation here.
#   - config loading. That is a RULE, not a function: every tunable is ${VAR:-default} at the
#     top of the script. No sourced sibling .conf, no $HOME/.dotfiles absolute path.

[ -n "${SELF:-}" ] || {
  printf 'panel-lib: the caller must set SELF before sourcing me (see the header)\n' >&2
  return 1 2>/dev/null || exit 1
}

# `-u` catches the typo'd variable that would otherwise expand to empty and let the script
# carry on with a wrong value. `pipefail` because these scripts are pipelines end to end.
#
# Deliberately NO `-e`. Not one panel uses it, and that is correct rather than sloppy: a
# `grep -q` miss and a failing command substitution are normal control flow here, so `-e`
# would abort a picker mid-render. CONVENTIONS.md carries the long version.
set -uo pipefail

PANEL_DIR="${SELF%/*}"
PANEL_NAME="$(basename "$SELF" .sh)"

# One PATH append, idempotent, replacing the five divergent copies of
#   export PATH="$PATH:/usr/local/bin:$HOME/.local/bin:$HOME/bin"
# A popup inherits the server's environment, not an interactive shell's, so ~/.local/bin is
# not necessarily on it -- which is why those copies existed.
case ":$PATH:" in
*":$HOME/.local/bin:"*) ;;
*) PATH="$PATH:$HOME/.local/bin" ;;
esac
export PATH

PANEL_TAB=$'\t'

# ── Palette ──────────────────────────────────────────────────────────────────
# The C_* names and the $'..' form, taken from notes-cockpit.sh and fleet.sh (the two
# largest and newest surfaces, so they win on volume and recency).
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
  C_HEAD='' C_SEL='' C_INP='' C_ERR='' C_DIM='' C_BOX='' C_PROJ='' C_ACC='' C_OFF=''
else
  C_HEAD=$'\033[1;37m' # section header (bold white)
  C_SEL=$'\033[1;32m'  # healthy / active / selected (bold green)
  C_INP=$'\033[1;33m'  # in-progress / needs attention (yellow)
  C_ERR=$'\033[1;31m'  # failed / tripped (bold red)
  C_DIM=$'\033[90m'    # dim
  C_BOX=$'\033[36m'    # checkbox / accent (cyan)
  C_PROJ=$'\033[1;35m' # project sub-header (magenta)
  C_ACC=$'\033[1;34m'  # blue accent
  C_OFF=$'\033[0m'
fi

# Glyph vocabulary, shared with claude-status.sh and agent-panel/src/fzf.rs so every surface
# reports agent state the same way: ! needs you · ~ working · ✓ healthy · · idle
G_ATTN='!'
G_BUSY='~'
G_OK='✓'
G_IDLE='·'

# ── Diagnostics ──────────────────────────────────────────────────────────────
# stderr ALWAYS, plus a best-effort tmux flash. tags.sh:59's idiom, and strictly better than
# favourites.sh:34's, which REPLACES stderr with the flash -- scripts and agents call these
# as CLIs and need the reason, not just an exit code. The flash is additive, for keybindings.
panel_warn() {
  printf '%s: %s\n' "$PANEL_NAME" "$*" >&2
  tmux display-message "$PANEL_NAME: $*" 2>/dev/null || true
}

# `panel_fail` returns; `panel_die` exits. tags.sh:66's rule, verbatim, because it is the
# kind of thing that gets "simplified" back into a single die():
#
#   A helper running inside a command substitution MUST use fail + return 1. An `exit` there
#   kills only the subshell, leaving the caller to carry on with an EMPTY result -- and for a
#   filter, to silently fall back to matching everything.
panel_fail() {
  panel_warn "$@"
  return 1
}
panel_die() {
  panel_warn "$@"
  exit 1
}

# panel_have <cmd> -- rc only, no output. Replaces ~20 copies of `command -v x >/dev/null`.
panel_have() { command -v "$1" >/dev/null 2>&1; }

# panel_need <cmd>... -- hard-die naming the FIRST missing one. For a dependency the surface
# cannot render without at all. When a section can degrade instead, use panel_have + a
# panel_hint row (fleet.sh:199 is the model, and is better behaviour than dying).
panel_need() {
  local c
  for c in "$@"; do
    panel_have "$c" || panel_die "$c is not on PATH"
  done
}

# panel_usage [file] -- print the header comment block, however long it grows.
# tags.sh:498's awk. Replaces servers.sh:436's `sed -n '2,40p'`, whose hardcoded line range
# silently truncates the moment the header outgrows it.
panel_usage() {
  awk 'NR==1 {next} /^#/ {sub(/^# ?/,""); print; next} {exit}' "${1:-$SELF}"
}

# ── Row helpers ──────────────────────────────────────────────────────────────
panel_head() { printf '%s── %s ──%s\n' "$C_HEAD" "$1" "$C_OFF"; }
panel_hint() { printf '%s  %s%s\n' "$C_DIM" "$1" "$C_OFF"; }

# panel_glyph_color <glyph> -- the colour that glyph always carries, so the mapping lives
# once instead of in fleet.sh three times and pr-viewer.sh's colorize_status.
panel_glyph_color() {
  case "$1" in
  "$G_ATTN") printf '%s' "$C_ERR" ;;
  "$G_BUSY") printf '%s' "$C_INP" ;;
  "$G_OK") printf '%s' "$C_SEL" ;;
  *) printf '%s' "$C_DIM" ;;
  esac
}

panel_paint() { printf '%s%s%s' "$(panel_glyph_color "$1")" "$1" "$C_OFF"; }

# ── fzf ──────────────────────────────────────────────────────────────────────
# panel_fzf_opts -- sets PANEL_FZF_OPTS, the base every picker starts from.
#
# An ARRAY, never a string. The test sandbox's path contains a space BY DESIGN
# (tests/helpers/sandbox.bash:32), so a re-split string is precisely the bug that harness
# exists to catch.
#
# --no-input, --cycle and --wrap are NOT here: they are per-surface choices (modal nav,
# pre-ordered lists), not a floor.
panel_fzf_opts() {
  PANEL_FZF_OPTS=(--ansi --reverse --border)
}

# panel_fzf_table -- the extra flags a pre-ordered TSV list wants on top of the base.
panel_fzf_table() {
  PANEL_FZF_TABLE=(--cycle --no-sort --wrap --delimiter="$PANEL_TAB")
}

# panel_fzf_preview <side> <percent> -- emit --preview-window in the MODERN COMMA form.
#
# fzf accepts both `left:24%:wrap:border-right` and `left,24%,border-right,wrap`; the colon
# form is legacy and is what notes-cockpit.sh, favourites.sh and agent-panel each spell
# differently. One function, one dialect.
panel_fzf_preview() {
  local side="$1" pct="$2" border
  case "$side" in
  left) border='border-right' ;;
  right) border='border-left' ;;
  up | top) border='border-bottom' ;;
  down | bottom) border='border-top' ;;
  *) panel_fail "unknown preview side: $side" || return 1 ;;
  esac
  printf -- '--preview-window=%s,%s%%,%s,wrap\n' "$side" "$pct" "$border"
}

# ── tmux ─────────────────────────────────────────────────────────────────────
panel_in_tmux() { [ -n "${TMUX:-}" ]; }

# panel_session_name <dir> -- the tmux session name a directory carries.
#
# Leading dot STRIPPED, then any remaining dot folded to an underscore. Both halves are
# load-bearing and they answer different failures:
#
#   the strip -- `~/.dotfiles` is the project `dotfiles` to every other layer of this repo
#     (project-name.sh:resolve_project_name, and .config/tmux-servers/hub.conf names the
#     session `dotfiles` by hand). A picker that folded instead of stripped produced
#     `_dotfiles`, so Prefix+f on ~/.dotfiles opened a SECOND session beside the one already
#     sitting there -- same directory, two sessions, neither one wrong-looking.
#   the fold  -- tmux reads `.` as the window separator inside a target, so `-t my.project`
#     addresses window "project" of session "my", not a session named `my.project`.
#
# One copy, because there were three and they disagreed: sessionizer.sh and favourites.sh
# folded only, worktree.sh stripped and folded while its comment credited sessionizer with a
# rule sessionizer did not have.
panel_session_name() {
  local base
  base="$(basename -- "$1")"
  base="${base#.}"
  printf '%s\n' "${base//./_}"
}

# panel_focus_session <name> / panel_focus_window <target>
# switch-client inside tmux, attach outside. Three correct copies existed (cockpit.sh:90,
# favourites.sh:302, agent-panel/src/tmux.rs:75); this is the fourth and last.
panel_focus_session() {
  if panel_in_tmux; then
    tmux switch-client -t "$1"
  else
    tmux attach -t "$1"
  fi
}

panel_focus_window() {
  panel_in_tmux || panel_die "not inside tmux, cannot select a window"
  tmux select-window -t "$1"
}

# panel_ensure_session <name> [dir] -- create it detached if it does not exist. Idempotent
# and keyed on NAME, so it is both the boot path and the repair path.
panel_ensure_session() {
  local name="$1" dir="${2:-$HOME}"
  tmux has-session -t "=$name" 2>/dev/null && return 0
  tmux new-session -ds "$name" -c "$dir"
}

# panel_new_window <cmd...> -- open a window, or say why not.
#
# THE FIX for notes-cockpit.sh:909-911, which calls `tmux new-window` with no $TMUX check and
# swallows the failure with 2>/dev/null -- so run outside tmux it silently does NOTHING,
# which reads to the user as the key not working.
panel_new_window() {
  panel_in_tmux || panel_die "not inside tmux, cannot open a window"
  tmux new-window "$@"
}
