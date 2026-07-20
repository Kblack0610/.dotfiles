#!/usr/bin/env bash
# notes-cockpit.sh — a native fzf task cockpit over EVERY notes profile + projects.
#
# Same practice as agent-panel / sessionizer.sh: fzf + tmux stay the UI, the `notes`
# Rust CLI stays the data + mutation core. NO editor is involved in the picker itself,
# so Esc just closes the popup (unlike an nvim-hosted picker, which drops you on the
# dashboard). nvim opens ONLY when you deliberately press Enter to edit a task's line.
#
# Data:   `notes focus --all`  -> profile<TAB>file<TAB>line<TAB>key<TAB>text
#         `notes projects`     -> name<TAB>summary<TAB>status
# Writes: `notes --profile <p> focus done|rm|add …`  (the vault-safe CLI verbs)
#
# Row wire format (TAB-delimited), consumed by fzf with --with-nth=6..:
#   1 type(task|proj)  2 profile  3 file  4 line  5 key  6 DISPLAY(shown, ANSI)
#
# Modes: (no args)=UI · --list=emit rows (initial + reload) · --preview · --add · --jump

set -uo pipefail
SELF="$(realpath "$0")"

C_PROF=$'\033[1;33m' # profile tag (yellow)
C_PROJ=$'\033[1;35m' # projects tag (magenta)
C_BOX=$'\033[36m'    # checkbox (cyan)
C_DIM=$'\033[90m'    # dim (status)
C_OFF=$'\033[0m'

# ── emit the fzf rows (tasks across all profiles, then projects) ─────
list_rows() {
  notes focus --all 2>/dev/null | while IFS=$'\t' read -r profile file line key text; do
    [ -z "$profile" ] && continue
    # display: drop the <!-- since --> comment and the checkbox, keep the (Nd) age
    local disp
    disp="$(printf '%s' "$text" | sed -E 's/ *<!--[^>]*-->//; s/^[[:space:]]*- \[[ xX]\] //')"
    printf 'task\t%s\t%s\t%s\t%s\t%s%-18s%s %s[ ]%s %s\n' \
      "$profile" "$file" "$line" "$key" \
      "$C_PROF" "$profile" "$C_OFF" "$C_BOX" "$C_OFF" "$disp"
  done

  notes projects 2>/dev/null | while IFS=$'\t' read -r name summary status; do
    [ -z "$name" ] && continue
    printf 'proj\t\t%s\t1\t%s\t%s%-18s%s %s>%s %s  %s%s%s\n' \
      "$summary" "$name" \
      "$C_PROJ" "projects" "$C_OFF" "$C_PROJ" "$C_OFF" "$name" "$C_DIM" "$status" "$C_OFF"
  done
}

# ── fzf preview: the file around the task line (or the project summary) ──
preview_row() {
  local file="$3" line="$4"
  [ -f "$file" ] || { echo "(no file)"; return 0; }
  local ln="${line:-1}"; [[ "$ln" =~ ^[0-9]+$ ]] || ln=1
  local from=$(( ln > 8 ? ln - 8 : 1 ))
  if command -v bat >/dev/null 2>&1; then
    bat --style=numbers --color=always --highlight-line "$ln" \
        --line-range "${from}:$(( ln + 24 ))" "$file" 2>/dev/null && return 0
  fi
  sed -n "${from},$(( ln + 24 ))p" "$file"
}

# ── ctrl-a: prompt for a new task and add it to the row's profile ──────
add_task() {
  local profile="$1"
  [ -z "$profile" ] && return 0
  local text
  read -r -p "add to ${profile}: " text || return 0
  [ -n "${text// /}" ] && notes --profile "$profile" focus add "$text"
}

# ── enter: open the task's line in a new tmux window (deliberate edit) ──
jump_row() {
  local type="$1" file="$2" line="$3"
  [ "$type" = "task" ] || [ "$type" = "proj" ] || return 0
  [ -f "$file" ] || return 0
  local ln="${line:-1}"; [[ "$ln" =~ ^[0-9]+$ ]] || ln=1
  tmux new-window "nvim +${ln} '$file'"
}

case "${1:-}" in
  --list) list_rows; exit 0 ;;
  --preview) shift; preview_row "$@"; exit 0 ;;
  --add) add_task "${2:-}"; exit 0 ;;
  --jump) shift; jump_row "$@"; exit 0 ;;
esac

command -v fzf >/dev/null 2>&1 || { echo "fzf not found on PATH"; exit 1; }
command -v notes >/dev/null 2>&1 || { echo "notes CLI not found (build ~/.dotfiles/.local/src/notes-cli)"; exit 1; }

HEADER='enter edit   C-x done   C-a add   C-d del   C-/ preview   esc quit'

list_rows | fzf \
  --ansi --reverse --border --cycle --no-sort \
  --delimiter=$'\t' --with-nth='6..' \
  --prompt='cockpit > ' \
  --header="$HEADER" \
  --preview "$SELF --preview {1} {2} {3} {4} {5}" \
  --preview-window 'right:52%:wrap' \
  --bind 'ctrl-/:toggle-preview' \
  --bind "ctrl-x:execute-silent(notes --profile {2} focus done {5})+reload($SELF --list)" \
  --bind "ctrl-d:execute-silent(notes --profile {2} focus rm {5})+reload($SELF --list)" \
  --bind "ctrl-a:execute($SELF --add {2})+reload($SELF --list)" \
  --bind "enter:execute-silent($SELF --jump {1} {3} {4})+abort"
