#!/usr/bin/env bash
# close.sh - the one way automation closes a tmux window or session. On PATH as `tmux-close`.
#
#   tmux-close [-L name | -S path] window <@id|%pane>
#   tmux-close [-L name | -S path] session <name> [--window <@id|%pane>]
#   tmux-close protected <name>      exit 0 when <name> is a world session, printing its manifest
#
# A world session is one a world manifest declares ($TMUX_SERVERS_DIR/*.conf, read by `tmx
# ensure`): hub, dotfiles, lab and the rest the human works in. Automation never kills one.
# Asked to close one, `session` closes the --window it was given instead, or refuses (exit 3)
# when it has none. A session an agent made (a `wt` worktree session, a dispatch session) is
# not declared, so it closes. Every closer calls this: agent-queue cancel, wind-down fire, wt done.
# Why: 2026-11-04 `agent-queue cancel` of a hand-started item killed hub:dotfiles, every
# window in it, because the item recorded the session it was started in.
set -uo pipefail

. "$(dirname "$(realpath "${BASH_SOURCE[0]}")")/worlds.sh" || exit 1

# protected <name> -> the manifest that declares <name>, exit 1 when none does. Any world's
# manifest counts on any server, a hidden one too: a name the human works in is never a
# disposable session. `?name` is declared on demand, `name:window` declares a window of session
# name. Fed by `<<<` for the reason world_of_dir gives.
protected() {
  local f name rest
  for f in "$MANIFEST_DIR"/*.conf; do
    [ -r "$f" ] || continue
    while read -r name rest; do
      name="${name#\?}"
      [ "${name%%:*}" = "$1" ] || continue
      printf '%s\n' "$f"
      return 0
    done <<< "$(world_entries "$f")"
  done
  return 1
}

die() { echo "tmux-close: $*" >&2; exit 2; }

main() {
  local tm=(tmux)
  case "${1:-}" in
    -L | -S) [ -n "${2:-}" ] || die "$1 needs a value"; tm+=("$1" "$2"); shift 2 ;;
  esac
  local verb="${1:-}"; shift || true
  case "$verb" in
    protected)
      protected "${1:?usage: tmux-close protected <name>}" ;;
    window)
      local w="${1:?usage: tmux-close window <@id|%pane>}"
      "${tm[@]}" kill-window -t "$w" ;;
    session)
      local s="${1:?usage: tmux-close session <name> [--window <@id|%pane>]}" w='' m
      shift
      case "${1:-}" in --window) w="${2:?--window needs a value}" ;; '') ;; *) die "unknown arg: $1" ;; esac
      if m="$(protected "$s")"; then
        if [ -n "$w" ]; then
          echo "tmux-close: $s is a world session ($m): closing window $w only"
          "${tm[@]}" kill-window -t "$w"
          return
        fi
        echo "tmux-close: $s is a world session ($m): not closed" >&2
        return 3
      fi
      "${tm[@]}" kill-session -t "=$s" ;;
    *) die "usage: tmux-close [-L name | -S path] window <id> | session <name> [--window <id>] | protected <name>" ;;
  esac
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0
main "$@"
