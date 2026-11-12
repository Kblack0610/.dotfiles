#!/usr/bin/env bash
# notes-find.sh - a live finder over what the notes vault knows (tmux Prefix+k).
#
# Usage: notes-find.sh [verb]
#
# Verbs:
#   --rows <query>          the hits for a query, TSV `path<TAB>line<TAB>label`, best first
#   --preview <path> <line> the note from a few lines above its best line
#   --help, -h              this text
#   (no verb)               open the picker
#
# Every keystroke re-runs `notes find`, which ranks notes across knowledge/, zettels, refs,
# employment/ and lab/: words in any order, typos and half-typed words still match, `#tag`
# filters (a folder name counts, so `#interview` hits interviews/), `"a phrase"` boosts,
# `-word` excludes. fzf only displays (--disabled), so the CLI's ranking stands. Enter opens
# the note at its best line in the hub notes editor (`tmx open hub`), or nvim outside tmux.
# The same lookup is <leader>nk in nvim (notes.nvim `notes.find`).

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

NOTES_BIN="${NOTES_BIN:-notes}"
NOTES_FIND_LIMIT="${NOTES_FIND_LIMIT:-50}"
NOTES_FIND_VAULT="${NOTES_FIND_VAULT:-$HOME/.notes/}"

# ── Rows ─────────────────────────────────────────────────────────────────────
# Path and line first (hidden by --with-nth), then the label: title, where, snippet.
cmd_rows() {
  local q="${1:-}"
  [[ -z "${q// /}" ]] && return 0
  "$NOTES_BIN" find -n "$NOTES_FIND_LIMIT" -- "$q" 2>/dev/null |
    awk -F'\t' -v vault="$NOTES_FIND_VAULT" -v b="$C_BOLD" -v d="$C_DIM" -v o="$C_OFF" '
      NF >= 5 {
        rel = $1
        if (index(rel, vault) == 1) rel = substr(rel, length(vault) + 1)
        printf "%s\t%s\t%s%s%s  %s%s:%s%s  %s\n", $1, $2, b, $4, o, d, rel, $2, o, $5
      }'
  return 0
}

# ── Preview ──────────────────────────────────────────────────────────────────
cmd_preview() {
  local path="$1" line="${2:-1}" start
  start=$((line > 5 ? line - 5 : 1))
  if panel_have bat; then
    bat --color=always --style=numbers --highlight-line "$line" \
      --line-range "${start}:" "$path" 2>/dev/null && return 0
  fi
  nl -ba -w4 -s' | ' "$path" | sed -n "${start},\$p"
}

# ── Picker ───────────────────────────────────────────────────────────────────
cmd_pick() {
  panel_need fzf
  panel_need "$NOTES_BIN"

  panel_fzf_opts
  panel_fzf_table
  panel_fzf_layout side

  local self sel path line
  self="$(printf '%q' "$SELF")"
  sel="$(: | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
    --disabled --with-nth=3 \
    --prompt='find > ' \
    --header='words in any order, #tag, "phrase", -word | Enter opens | Esc closes' \
    --bind="change:reload($self --rows {q})" \
    "${PANEL_FZF_LAYOUT[@]}" \
    --preview="$self --preview {1} {2}")"
  [ -n "$sel" ] || return 0
  path="$(cut -f1 <<<"$sel")"
  line="$(cut -f2 <<<"$sel")"

  if panel_in_tmux && panel_have tmx; then
    exec tmx open hub "$path" "$line"
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
