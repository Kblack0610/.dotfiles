#!/usr/bin/env bash
#
# notes-tags - a fzf finder window over the notes vault's tags.
#
# Two stages: pick a #tag (preview shows its matching lines), then pick a
# matching note line (preview shows the note around the hit). Enter opens the
# note in nvim at that line.
#
# Backed by the `notes tags` subcommand (Rust CLI): tab-delimited output,
#   `notes tags`         -> "<tag>\t<count>"
#   `notes tags <name>`  -> "<path>\t<line>\t<text>"
#
# Self-calls (used internally by fzf's --preview):
#   notes-tags --preview-tag <tag>
#   notes-tags --preview-hit <path> <line>

set -euo pipefail

NOTES_BIN="${NOTES_BIN:-notes}"

# ── Preview modes (self-calls from fzf) ─────────────────────────
case "${1:-}" in
    --preview-tag)
        "$NOTES_BIN" tags "$2" | cut -f3- | sed 's/^/  /'
        exit 0
        ;;
    --preview-hit)
        path="$2"; line="${3:-1}"
        if command -v bat >/dev/null 2>&1; then
            bat --color=always --style=numbers \
                --highlight-line "$line" \
                --line-range "$((line > 5 ? line - 5 : 1)):$((line + 15))" \
                "$path" 2>/dev/null && exit 0
        fi
        # Fallback: a plain window around the hit line
        start=$((line > 5 ? line - 5 : 1))
        end=$((line + 15))
        nl -ba -w4 -s' │ ' "$path" | sed -n "${start},${end}p"
        exit 0
        ;;
esac

command -v "$NOTES_BIN" >/dev/null 2>&1 || { echo "notes CLI not found on PATH"; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }

# ── Stage 1: pick a tag ─────────────────────────────────────────
# Entry: <tag>\t<label>  (label = "tag  (count)"); --with-nth shows the label.
tag_input="$("$NOTES_BIN" tags | awk -F'\t' 'NF>=2 { printf "%s\t%s  (%s)\n", $1, $1, $2 }')"

if [[ -z "$tag_input" ]]; then
    echo "No tags found. Add an inline #hashtag or a frontmatter 'tags:' entry to a note."
    exit 0
fi

tag_sel="$(printf '%s\n' "$tag_input" | fzf \
    --reverse --border --cycle --ansi \
    --delimiter=$'\t' --with-nth=2 \
    --prompt='tag > ' \
    --height=90% \
    --preview="$0 --preview-tag {1}" \
    --preview-window=right:60%:wrap \
    --header='Enter=browse this tag | esc=cancel')" || exit 0

[[ -z "$tag_sel" ]] && exit 0
tag="$(printf '%s' "$tag_sel" | cut -f1)"

# ── Stage 2: pick a matching note line ──────────────────────────
# Entry: <path>\t<line>\t<text>; --with-nth=3 shows the line text.
hit_input="$("$NOTES_BIN" tags "$tag")"
[[ -z "$hit_input" ]] && { echo "No hits for #$tag."; exit 0; }

hit_sel="$(printf '%s\n' "$hit_input" | fzf \
    --reverse --border --cycle --ansi \
    --delimiter=$'\t' --with-nth=3 \
    --prompt="#$tag > " \
    --height=90% \
    --preview="$0 --preview-hit {1} {2}" \
    --preview-window=right:60%:wrap \
    --header='Enter=open in nvim | esc=back-out')" || exit 0

[[ -z "$hit_sel" ]] && exit 0
path="$(printf '%s' "$hit_sel" | cut -f1)"
line="$(printf '%s' "$hit_sel" | cut -f2)"

exec nvim "+${line}" "$path"
