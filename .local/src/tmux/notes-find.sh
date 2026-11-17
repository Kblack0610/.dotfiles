#!/usr/bin/env bash
# notes-find.sh - a live finder over the whole notes vault (tmux Prefix+k).
#
# Usage: notes-find.sh [verb]
#
# Verbs:
#   --rows <query>          the hits for a query, TSV `path<TAB>line<TAB>label`, best first
#   --preview <path> <line> the whole note, its best line highlighted
#   --help, -h              this text
#   (no verb)               open the picker
#
# Every keystroke re-runs `notes find`, which ranks every note in the vault: words in any
# order, typos and half-typed words still match, `#tag` filters (a folder name counts, so
# `#interview` hits interviews/), `"a phrase"` boosts, `-word` excludes. fzf only displays
# (--disabled), so the CLI's ranking stands. A hit is one row, its title and folder; the
# preview opens on the hit's line (panel_preview_extra scrolls it there). Enter opens the
# note at that line in the hub notes editor (`tmx open hub`), or nvim outside tmux.
# The same lookup is <leader>nk in nvim (notes.nvim `notes.find`).

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

NOTES_BIN="${NOTES_BIN:-notes}"
NOTES_FIND_LIMIT="${NOTES_FIND_LIMIT:-50}"
NOTES_FIND_VAULT="${NOTES_FIND_VAULT:-$HOME/.notes/}"

# --- Rows ---------------------------------------------------------------------
# Path and line first (hidden by --with-nth), then the label: the title, and dim, the folder
# it sits in under the vault. The CLI's snippet is left out: the preview shows that line.
cmd_rows() {
  local q="${1:-}"
  [[ -z "${q// /}" ]] && return 0
  "$NOTES_BIN" find -n "$NOTES_FIND_LIMIT" -- "$q" 2>/dev/null |
    awk -F'\t' -v vault="$NOTES_FIND_VAULT" -v b="$C_BOLD" -v d="$C_DIM" -v o="$C_OFF" '
      NF >= 5 {
        dir = $1
        if (index(dir, vault) == 1) dir = substr(dir, length(vault) + 1)
        if (!sub(/\/[^\/]*$/, "", dir)) dir = "."
        printf "%s\t%s\t%s%s%s  %s%s%s\n", $1, $2, b, $4, o, d, dir, o
      }'
  return 0
}

# --- Preview ------------------------------------------------------------------
# The whole note, so scrolling up reaches its title; fzf opens it on the hit's line.
cmd_preview() {
  local path="$1" line="${2:-1}"
  if panel_have bat; then
    bat --color=always --style=plain --highlight-line "$line" "$path" 2>/dev/null && return 0
  fi
  cat "$path"
}

# --- Picker -------------------------------------------------------------------
cmd_pick() {
  panel_need fzf
  panel_need "$NOTES_BIN"

  panel_fzf_opts
  panel_fzf_table
  panel_fzf_layout side

  local self sel path line
  self="$(printf '%q' "$SELF")"
  # --no-wrap: a hit is one row, and a long title clips instead of adding rows.
  sel="$(: | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" --no-wrap \
    --disabled --with-nth=3 \
    --prompt='find > ' \
    --header='enter open  ctrl-/ layout  esc close    #tag  "phrase"  -word' \
    --bind="change:reload($self --rows {q})" \
    "${PANEL_FZF_LAYOUT[@]}" \
    --preview="$self --preview {1} {2}")"
  [ -n "$sel" ] || return 0
  path="$(cut -f1 <<<"$sel")"
  line="$(cut -f2 <<<"$sel")"

  # tmx refuses when the hub pane runs something other than nvim or a shell; the hit then
  # opens here instead of being lost with the popup.
  if panel_in_tmux && panel_have tmx && tmx open hub "$path" "$line"; then
    return 0
  fi
  exec nvim "+${line}" "$path"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
--rows) cmd_rows "${2:-}" ;;
--preview) cmd_preview "${2:?path}" "${3:-1}" ;;
'') cmd_pick ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
