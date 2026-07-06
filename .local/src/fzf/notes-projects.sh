#!/usr/bin/env bash
#
# notes-projects - a fzf finder window over the notes vault's indexed projects.
#
# Two stages: pick a project (preview shows its summary.md), then pick a file
# inside it (preview shows that file). Enter opens the file in nvim. Same shape
# as notes-tags.sh, over the projects that populate the daily note's
# `## Current Projects` block.
#
# Backed by the `notes projects` subcommand (Rust CLI): tab-delimited output,
#   notes projects          -> "<name>\t<summary-path>\t<status>"
#   notes projects <name>    -> "<path>\t<label>"
#
# Self-calls (used internally by fzf's --preview):
#   notes-projects --preview-file <path>

set -euo pipefail

NOTES_BIN="${NOTES_BIN:-notes}"

# ── Preview mode (self-call from fzf) ───────────────────────────
preview_file() {
    local path="$1"
    if command -v bat >/dev/null 2>&1; then
        bat --color=always --style=numbers --line-range=:120 "$path" 2>/dev/null && return 0
    fi
    nl -ba -w4 -s' │ ' "$path" 2>/dev/null | sed -n '1,120p'
}

case "${1:-}" in
    --preview-file)
        preview_file "$2"
        exit 0
        ;;
esac

command -v "$NOTES_BIN" >/dev/null 2>&1 || { echo "notes CLI not found on PATH"; exit 1; }
command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }

# ── Stage 1: pick a project ─────────────────────────────────────
# Entry: <name>\t<summary>\t<status>; --with-nth=1,3 shows "name  status",
# preview renders the summary (column 2 = its path).
proj_input="$("$NOTES_BIN" projects)"

if [[ -z "$proj_input" ]]; then
    echo "No indexed projects. Add one under lab/projects/current/<name>/summary.md"
    exit 0
fi

proj_sel="$(printf '%s\n' "$proj_input" | fzf \
    --reverse --border --cycle --ansi \
    --delimiter=$'\t' --with-nth=1,3 \
    --prompt='project > ' \
    --height=90% \
    --preview="$0 --preview-file {2}" \
    --preview-window=right:60%:wrap \
    --header='Enter=browse this project | esc=cancel')" || exit 0

[[ -z "$proj_sel" ]] && exit 0
name="$(printf '%s' "$proj_sel" | cut -f1)"

# ── Stage 2: pick a file inside the project ─────────────────────
# Entry: <path>\t<label>; --with-nth=2 shows the label.
file_input="$("$NOTES_BIN" projects "$name")"
[[ -z "$file_input" ]] && { echo "No files for $name."; exit 0; }

file_sel="$(printf '%s\n' "$file_input" | fzf \
    --reverse --border --cycle --ansi \
    --delimiter=$'\t' --with-nth=2 \
    --prompt="$name > " \
    --height=90% \
    --preview="$0 --preview-file {1}" \
    --preview-window=right:60%:wrap \
    --header='Enter=open in nvim | esc=back-out')" || exit 0

[[ -z "$file_sel" ]] && exit 0
path="$(printf '%s' "$file_sel" | cut -f1)"

exec nvim "$path"
