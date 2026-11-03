#!/usr/bin/env bash
# harpoon.sh (`tmux-harpoon`) - pin tmux WINDOWS to numbered slots, like nvim's harpoon.
#   Prefix+a    toggle     pin / unpin this window (two windows of a session = two slots)
#   M-1..M-4    jump <n>   jump to slot n
#   Prefix+e    menu       edit the list in $EDITOR: reorder lines, delete to unpin, Esc/q
#   ls | file              print the slots | print the list's path
#
# One line per slot: server, session, window id, session_created, window name (a label,
# never matched). A file, not a tmux option, because it is ordered, spans servers and
# outlives a kill-server. Ids restart after one, so the stamp must still match or the jump
# lands on the session; a 2-field line is a plain session pin. Same server: switch-client;
# anything else: `tmx goto`, which crosses worlds, drops the Prefix+L crumb, wakes a session.

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

# The matched part of a slot line: server, session, window id, stamp.
key() { awk -F'\t' '{ print $1 FS $2 FS $3 FS $4 }'; }

# "<server>\t<session>\t<window_id>\t<session_created>\t<window_name>" of the calling
# client, in one display-message so every field describes the same moment.
here() {
  local loc sock sess rest
  [ -n "${TMUX:-}" ] || return 1
  loc="$(tmux display-message -p "#{socket_path}"$'\t'"#{session_name}"$'\t'"#{window_id}"$'\t'"#{session_created}"$'\t'"#{window_name}" 2>/dev/null)" || return 1
  IFS=$'\t' read -r sock sess rest <<<"$loc"
  [ -n "$sock" ] && [ -n "$sess" ] || return 1
  printf '%s\t%s\t%s\n' "${sock##*/}" "$sess" "$rest"
}

# live_name <server> <session> <window_id> <stamp> -- the window's current name, or fail
# when the window is gone or the session was recreated since the pin (ids get reused).
live_name() {
  tmux -L "$1" list-windows -t "=$2" -F "#{session_created}"$'\t'"#{window_id}"$'\t'"#{window_name}" 2>/dev/null |
    awk -F'\t' -v s="$4" -v w="$3" '$1 == s && $2 == w { print $3; f = 1; exit } END { exit !f }'
}

cmd_toggle() {
  local cur k rest n name
  cur="$(here)" || { say "not inside tmux"; return 0; }
  k="$(key <<<"$cur")"
  name="$(cut -f2 <<<"$cur"):$(cut -f5 <<<"$cur")"
  mkdir -p "${HARPOON_FILE%/*}"
  if slots | key | grep -qxF -- "$k"; then
    rest="$(slots | awk -F'\t' -v k="$k" '($1 FS $2 FS $3 FS $4) != k')"
    printf '%s' "${rest:+$rest$'\n'}" > "$HARPOON_FILE"
    say "unpinned $name"
  else
    rest="$(slots)"
    printf '%s%s\n' "${rest:+$rest$'\n'}" "$cur" > "$HARPOON_FILE"
    n="$(slots | wc -l | tr -d ' ')"
    say "$name -> slot $n"
  fi
}

# at_slot <cur> <row> -- is the client already where this slot points? A session pin
# matches anywhere in its session, a window pin only on its window.
at_slot() {
  local cur="$1" row="$2"
  case "$(cut -f3 <<<"$row")" in
    '') [ "$(cut -f1-2 <<<"$cur")" = "$(cut -f1-2 <<<"$row")" ] ;;
    *) [ "$(key <<<"$cur")" = "$(key <<<"$row")" ] ;;
  esac
}

cmd_jump() {
  local n="${1:-}" row srv sess wid stamp target cur cur_srv=""
  case "$n" in ''|*[!0-9]*|0) say "jump needs a slot number"; return 0 ;; esac
  row="$(slots | sed -n "${n}p")"
  [ -n "$row" ] || { say "slot $n is empty"; return 0; }
  IFS=$'\t' read -r srv sess wid stamp _ <<<"$row"

  if cur="$(here)"; then
    cur_srv="${cur%%$'\t'*}"
    at_slot "$cur" "$row" && return 0
  fi

  target="$sess"
  [ -n "${wid:-}" ] && live_name "$srv" "$sess" "$wid" "${stamp:-}" >/dev/null && target="$sess:$wid"

  if [ "$srv" = "$cur_srv" ] && tmux has-session -t "=$sess" 2>/dev/null; then
    [ "$target" = "$sess" ] || tmux select-window -t "=$target"
    tmux switch-client -t "=$sess"
    return 0
  fi

  panel_have tmx || { say "tmx is not on PATH"; return 0; }
  exec tmx goto "$srv" "$target"
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
  local cur="" i=0 row srv sess wid stamp label mark state live
  cur="$(here)" || cur=""
  while IFS= read -r row; do
    i=$((i + 1))
    IFS=$'\t' read -r srv sess wid stamp label <<<"$row"
    mark=" "; [ -n "$cur" ] && at_slot "$cur" "$row" && mark="*"
    state=""
    if ! tmux -L "$srv" has-session -t "=$sess" 2>/dev/null; then
      state="  (gone)"
    elif [ -n "${wid:-}" ]; then
      if live="$(live_name "$srv" "$sess" "$wid" "${stamp:-}")"; then label="$live"; else state="  (window gone)"; fi
    fi
    printf '%s %d  %-8s %s%s\n' "$mark" "$i" "$srv" "$sess${wid:+:${label:-$wid}}" "$state"
  done < <(slots)
  [ "$i" -gt 0 ] || echo "nothing pinned (Prefix+a pins this window)"
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
