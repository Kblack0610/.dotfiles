#!/usr/bin/env bash
#
# notes-find - a live fzf finder over the notes vault's knowledge (tmux Prefix+k).
#
# Every keystroke re-runs `notes find`, which ranks notes across knowledge/, zettels,
# refs, employment/ and lab/: words in any order, typos and half-typed words still match,
# `#tag` filters (a folder name counts, so `#interview` hits interviews/), `"a phrase"`
# boosts, `-word` excludes. fzf only displays: --disabled keeps the CLI's ranking.
# Enter opens the note at its best line in the hub notes editor (`tmx open hub`), or in a
# plain nvim outside tmux.
#
# Self-calls (used internally by fzf):
#   notes-find --rows <query>              -> "<path>\t<line>\t<display>"
#   notes-find --preview-hit <path> <line>

set -euo pipefail

NOTES_BIN="${NOTES_BIN:-notes}"
LIMIT="${NOTES_FIND_LIMIT:-50}"

case "${1:-}" in
    --rows)
        q="${2:-}"
        [[ -z "${q// /}" ]] && exit 0
        "$NOTES_BIN" find -n "$LIMIT" -- "$q" 2>/dev/null | awk -F'\t' -v home="$HOME/.notes/" '
            NF >= 5 {
                rel = $1; sub("^" home, "", rel)
                printf "%s\t%s\t\033[1m%s\033[0m  \033[2m%s:%s\033[0m  %s\n", $1, $2, $4, rel, $2, $5
            }' || true
        exit 0
        ;;
    --preview-hit)
        path="$2"; line="${3:-1}"
        start=$((line > 5 ? line - 5 : 1))
        if command -v bat >/dev/null 2>&1; then
            bat --color=always --style=numbers --highlight-line "$line" \
                --line-range "${start}:" "$path" 2>/dev/null && exit 0
        fi
        nl -ba -w4 -s' | ' "$path" | sed -n "${start},\$p"
        exit 0
        ;;
esac

command -v "$NOTES_BIN" >/dev/null 2>&1 || { echo "notes CLI not found on PATH"; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }

self="$(realpath "$0")"
sel="$(: | fzf \
    --disabled --ansi --reverse --cycle \
    --delimiter=$'\t' --with-nth=3 \
    --prompt='find > ' \
    --header='words in any order, #tag, "phrase", -word | Enter opens | Esc closes' \
    --bind "change:reload:$self --rows {q}" \
    --preview="$self --preview-hit {1} {2}" \
    --preview-window=right:55%:wrap:+{2}-5)" || exit 0

[[ -z "$sel" ]] && exit 0
path="$(printf '%s' "$sel" | cut -f1)"
line="$(printf '%s' "$sel" | cut -f2)"

if [[ -n "${TMUX:-}" ]] && command -v tmx >/dev/null 2>&1; then
    exec tmx open hub "$path" "$line"
fi
exec nvim "+${line}" "$path"
