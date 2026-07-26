#!/usr/bin/env bash
# servers.sh — the SERVER layer. On PATH as `tmx`.
#
# tmux has four layers; this repo only ever used the bottom three:
#
#   server   one per SOCKET   <- this script
#     session   hub, lab, ...
#       window
#         pane
#
# Every session used to live in ONE server on the default socket, which made them
# siblings rather than separate systems. That is not just untidy: a single
# `tmux kill-server` — from a stray test teardown, a wedged client, anything — takes
# out every session at once, because they share one process. Splitting hub / lab /
# work into their own sockets makes that blast radius exactly one server wide.
#
# What survives the split, verified:
#   - Inside a `-L foo` session $TMUX is set, so a bare `tmux ls` reports foo's
#     sessions, not the default server's.
#   - `sesh` shells out to plain `tmux`, so it follows the enclosing server with no
#     config change. One sesh.toml is correct inside every server.
#
# What does NOT survive: tmux cannot move a live session between servers. There is no
# `move-session -L`. Switching a session to another server means recreating it.
#
# Hopping between servers is `detach-client -E`: tmux has no cross-server
# switch-client (switch-client is session-scoped, within one server), but -E runs a
# command after the client detaches, so detach+attach reads as a single hop.
#
# Each server holds a SET of sessions, declared in .config/tmux-servers/<name>.conf.
# `ensure` creates only the ones that are missing, keyed on session name, so booting a
# world and repairing one are the same command — the pattern cockpit.sh already uses.
#
# Because sessions are per-socket, `Prefix+w` (choose-tree) inside a server can only
# ever list that server's sessions. That is the whole point and needs no code:
# choose-tree is server-scoped by construction.
#
# Verbs: <name> · ensure <name> · ls · pick · hop <name> · pick-session

set -uo pipefail

# server name -> start dir for its initial session. A name not listed here still
# works; it just boots at $HOME.
server_root() {
  case "$1" in
    hub) printf '%s\n' "$HOME" ;;
    lab) printf '%s\n' "$HOME/.notes/lab" ;;
    *)   printf '%s\n' "$HOME" ;;
  esac
}

# The servers we always offer, even when not yet running. Deliberately just two:
# hub (personal — notes + machine config) and lab (what I am building + the
# codebase I build it in). A third "work" server was tried and dropped as noise.
KNOWN_SERVERS=(hub lab)

SOCKET_DIR="${TMUX_TMPDIR:-/tmp}/tmux-$(id -u)"
MANIFEST_DIR="${TMUX_SERVERS_DIR:-$HOME/.config/tmux-servers}"
SESH_CONFIG_DIR="${SESH_CONFIG_DIR:-$HOME/.config/sesh}"

die() { printf 'tmx: %s\n' "$*" >&2; exit 1; }

command -v tmux >/dev/null 2>&1 || die "tmux not installed"

# Sockets that currently have a live server behind them.
live_servers() {
  [ -d "$SOCKET_DIR" ] || return 0
  local sock name
  for sock in "$SOCKET_DIR"/*; do
    [ -S "$sock" ] || continue
    name="${sock##*/}"
    # A socket file can outlive its server; only report ones that answer.
    tmux -L "$name" has-session 2>/dev/null && printf '%s\n' "$name"
  done
}

session_count() { tmux -L "$1" list-sessions 2>/dev/null | wc -l | tr -d ' '; }

# ls -- every known server plus any live one, with session counts.
cmd_ls() {
  local -a all=()
  local s
  for s in "${KNOWN_SERVERS[@]}"; do all+=("$s"); done
  while IFS= read -r s; do
    [ -n "$s" ] || continue
    case " ${all[*]} " in *" $s "*) ;; *) all+=("$s") ;; esac
  done < <(live_servers)

  for s in "${all[@]}"; do
    local n; n="$(session_count "$s")"
    if [ "$n" -gt 0 ]; then
      printf '%-10s %s session(s)\n' "$s" "$n"
    else
      printf '%-10s (not running)\n' "$s"
    fi
  done
}

# ensure <name> -- create every session in the manifest that is not already there.
# Idempotent and additive: it never renames, moves or kills an existing session, so
# running it against a live world is safe and is also how you repair one.
cmd_ensure() {
  local srv="${1:?ensure needs a server name}"
  local manifest="$MANIFEST_DIR/$srv.conf"
  local made=0 kept=0

  if [ ! -r "$manifest" ]; then
    # No manifest is not an error: an ad-hoc server just gets its default session.
    tmux -L "$srv" new-session -A -d -s "$srv" -c "$(server_root "$srv")" 2>/dev/null
    printf 'tmx: %s has no manifest (%s); booted a single "%s" session\n' \
      "$srv" "$manifest" "$srv" >&2
    return 0
  fi

  local name dir cmd
  while read -r name dir cmd; do
    case "$name" in ''|'#'*) continue ;; esac
    [ -n "$dir" ] || continue
    dir="${dir/#\~/$HOME}"           # manifests are written with ~
    if tmux -L "$srv" has-session -t "=$name" 2>/dev/null; then
      kept=$((kept + 1))
      continue
    fi
    # -d so ensure never steals the terminal; missing dirs fall back to $HOME
    # rather than aborting the whole world.
    [ -d "$dir" ] || dir="$HOME"
    tmux -L "$srv" new-session -d -s "$name" -c "$dir" 2>/dev/null || continue
    made=$((made + 1))
    # send-keys rather than `new-session <cmd>`: as a session command, quitting the
    # editor would kill the session. As keystrokes it lands back in a shell.
    #
    # Target MUST be "$name:" and not "=$name". The `=` exact-match prefix is only
    # valid for SESSION targets (has-session -t =x); against a pane target tmux
    # fails with "can't find pane", which silently no-ops every startup command.
    [ -n "$cmd" ] && tmux -L "$srv" send-keys -t "$name:" "$cmd" Enter
  done < "$manifest"

  printf 'tmx: %s — %d created, %d already up\n' "$srv" "$made" "$kept"
}

# pick-session -- the Prefix+S dispatch. Inside a NAMED server, scope the picker to
# that world's own sesh config and drop zoxide (-c -t, no -z), because the zoxide
# database is global and would otherwise make every server's list look the same.
# Inside the unnamed default server there is no world to scope to, so fall back to
# the global config and full behaviour.
cmd_pick_session() {
  command -v sesh >/dev/null 2>&1 || die "sesh not installed"
  local srv cfg
  srv="$(tmux display-message -p '#{socket_path}' 2>/dev/null)"
  srv="${srv##*/}"
  cfg="$SESH_CONFIG_DIR/$srv.toml"

  if [ -n "$srv" ] && [ "$srv" != "default" ] && [ -r "$cfg" ]; then
    sesh -C "$cfg" picker -i -d -c -t
  else
    sesh picker -i -d
  fi
}

# hop <name> -- leave the current server and land in <name>. Only meaningful from
# inside tmux; outside, attaching directly is the same thing.
cmd_hop() {
  local target="${1:?hop needs a server name}"

  if [ -n "${TMUX:-}" ]; then
    # -E runs after this client detaches, so the two halves read as one hop. The
    # world is ensured on the far side, not here, so a half-built server cannot
    # leave you detached from everything.
    tmux detach-client -E "$(printf '%q' "$0") hop $(printf '%q' "$target")"
    return 0
  fi

  cmd_ensure "$target" >/dev/null

  # Land on the manifest's FIRST session, not on whatever tmux last touched — that
  # is what makes hopping to hub open today's daily rather than a random shell.
  local landing
  landing="$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' \
    "$MANIFEST_DIR/$target.conf" 2>/dev/null)"

  if [ -n "$landing" ] && tmux -L "$target" has-session -t "=$landing" 2>/dev/null; then
    exec tmux -L "$target" attach -t "=$landing"
  fi
  exec tmux -L "$target" attach
}

# pick -- fzf over the servers. Enter hops.
cmd_pick() {
  command -v fzf >/dev/null 2>&1 || die "fzf not installed"
  local choice
  choice="$(cmd_ls | fzf --reverse --border \
    --prompt='server > ' \
    --header='Enter: hop to server · Esc: cancel' \
    --preview='tmux -L {1} list-sessions 2>/dev/null || echo "(not running - Enter starts it)"' \
    --preview-window=right,55%)" || return 0
  [ -n "$choice" ] || return 0
  cmd_hop "${choice%% *}"
}

main() {
  local verb="${1:-pick}"
  case "$verb" in
    ls|list)      cmd_ls ;;
    pick)         cmd_pick ;;
    hop)          shift; cmd_hop "${1:-}" ;;
    ensure)       shift; cmd_ensure "${1:-}" ;;
    pick-session) cmd_pick_session ;;
    -h|--help)    sed -n '2,40p' "$0" ;;
    *)            cmd_hop "$verb" ;;   # `tmx hub` is the common case
  esac
}

main "$@"
