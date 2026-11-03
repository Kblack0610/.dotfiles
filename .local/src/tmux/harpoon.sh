#!/usr/bin/env bash
# harpoon.sh (`tmux-harpoon`) - pin tmux SESSIONS to numbered slots, like nvim's harpoon.
#   Prefix+a    toggle     pin / unpin this session
#   M-1..M-4    jump <n>   jump to slot n
#   Prefix+e    menu       edit the list in $EDITOR: reorder lines, delete to unpin, Esc/q
#   ls | file              print the slots | print the list's path
#
# The list is a file of "<server><TAB><session>" lines, line number = slot, not a tmux
# option like tags.sh: it is ordered, spans servers, and outlives a kill-server. A jump
# in the current server is a switch-client; anything else goes to `tmx goto`, which
# crosses worlds, drops the Prefix+L crumb and wakes a declared session.

set -uo pipefail

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

HARPOON_FILE="${HARPOON_FILE:-${XDG_STATE_HOME:-$HOME/.local/state}/tmx/harpoon}"

# A message from a key, not a failure: run-shell turns a non-zero exit into a
# "returned 1" popup that reads as a broken binding.
say() {
  printf 'harpoon: %s\n' "$*"
  tmux display-message "harpoon: $*" 2>/dev/null || true
}

# Slots in order, blank and malformed lines dropped, so a stray empty line left by the
# menu never shifts the numbering.
slots() { awk -F'\t' 'NF >= 2 && $1 != "" && $2 != ""' "$HARPOON_FILE" 2>/dev/null; }

# "<server>\t<session>" of the calling client. One display-message so both fields
# describe the same moment, same as servers.sh _current_loc.
here() {
  local loc sock sess
  [ -n "${TMUX:-}" ] || return 1
  loc="$(tmux display-message -p "#{socket_path}"$'\t'"#{session_name}"$'\t'"#{window_index}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r sock sess _ <<<"$loc"
  [ -n "$sock" ] && [ -n "$sess" ] || return 1
  printf '%s\t%s\n' "${sock##*/}" "$sess"
}

cmd_toggle() {
  local cur rest n
  cur="$(here)" || { say "not inside tmux"; return 0; }
  mkdir -p "${HARPOON_FILE%/*}"
  if slots | grep -qxF -- "$cur"; then
    rest="$(slots | grep -vxF -- "$cur")"
    printf '%s' "${rest:+$rest$'\n'}" > "$HARPOON_FILE"
    say "unpinned ${cur#*$'\t'}"
  else
    rest="$(slots)"
    printf '%s%s\n' "${rest:+$rest$'\n'}" "$cur" > "$HARPOON_FILE"
    n="$(slots | wc -l | tr -d ' ')"
    say "${cur#*$'\t'} -> slot $n"
  fi
}

cmd_jump() {
  local n="${1:-}" row srv sess cur_srv=""
  case "$n" in ''|*[!0-9]*|0) say "jump needs a slot number"; return 0 ;; esac
  row="$(slots | sed -n "${n}p")"
  [ -n "$row" ] || { say "slot $n is empty"; return 0; }
  IFS=$'\t' read -r srv sess <<<"$row"

  if cur="$(here)"; then
    cur_srv="${cur%%$'\t'*}"
    [ "$cur" = "$row" ] && return 0
  fi

  if [ "$srv" = "$cur_srv" ] && tmux has-session -t "=$sess" 2>/dev/null; then
    tmux switch-client -t "=$sess"
    return 0
  fi

  panel_have tmx || { say "tmx is not on PATH"; return 0; }
  exec tmx goto "$srv" "$sess"
}

cmd_menu() {
  local tmp
  mkdir -p "${HARPOON_FILE%/*}"
  tmp="$(mktemp "${HARPOON_FILE}.XXXXXX")" || panel_die "cannot create a temp file"
  slots > "$tmp"
  local ed="${EDITOR:-nvim}"
  case "${ed##*/}" in
    # Esc and q save and close, like the nvim harpoon menu with save_on_toggle.
    nvim|vim) "$ed" -c 'nnoremap <buffer> <Esc> <Cmd>wq<CR>' -c 'nnoremap <buffer> q <Cmd>wq<CR>' "$tmp" ;;
    *) "$ed" "$tmp" ;;
  esac
  # Normalise on the way back in: blank lines dropped, duplicates collapsed to the first.
  awk -F'\t' 'NF >= 2 && $1 != "" && $2 != "" && !seen[$0]++' "$tmp" > "$HARPOON_FILE"
  rm -f "$tmp"
}

cmd_ls() {
  local cur="" i=0 srv sess mark state
  cur="$(here)" || cur=""
  while IFS=$'\t' read -r srv sess; do
    i=$((i + 1))
    mark=" "; [ "$srv"$'\t'"$sess" = "$cur" ] && mark="*"
    state=""; tmux -L "$srv" has-session -t "=$sess" 2>/dev/null || state="  (gone)"
    printf '%s %d  %-8s %s%s\n' "$mark" "$i" "$srv" "$sess" "$state"
  done < <(slots)
  [ "$i" -gt 0 ] || echo "no sessions pinned (Prefix+a pins this one)"
}

case "${1:-}" in
  toggle) cmd_toggle ;;
  jump)   shift; cmd_jump "${1:-}" ;;
  menu)   cmd_menu ;;
  ls)     cmd_ls ;;
  file)   printf '%s\n' "$HARPOON_FILE" ;;
  -h|--help|help|'') panel_usage ;;
  *)      panel_die "unknown verb: $1 (toggle | jump <n> | menu | ls | file)" ;;
esac
