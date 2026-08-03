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
# Verbs: <name> · ensure <name> · ls · pick · pick-all · rows · hop <name>
#        · root <name> · land <name> <last|root|session[:window]> · pick-session

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

# A landing session is long-lived, so whatever its editor opened on creation stays
# open — which for a DATE-DERIVED page means `root` quietly hands you an old note.
# That is exactly how a May-1st daily kept reappearing.
#
# `root` therefore restores the landing page in two cases:
#
#   1. The pane is back at a SHELL — you quit the editor. Re-run the manifest's
#      startup command, so the root page is genuinely a page and not the shell you
#      happen to have left behind.
#   2. The pane is running nvim on a daily that is NOT today's — switch the buffer
#      with `:e`. Escape first, in case the editor is in insert mode.
#
# Anything else (nvim on some other file, nvim already on today's note) is left
# alone: `root` restores the page, it does not hijack an editor you are using.
_refresh_landing() {
  local srv="$1" sess="$2" pane cmd title today startup

  pane="$(tmux -L "$srv" list-panes -t "$sess" -F '#{pane_id}' 2>/dev/null | head -1)"
  [ -n "$pane" ] || return 0
  cmd="$(tmux -L "$srv" display-message -p -t "$pane" '#{pane_current_command}' 2>/dev/null)"

  # Case 1: back at a shell -> re-run the manifest's startup command for this entry.
  case "$cmd" in
    sh|bash|zsh|fish)
      startup="$(awk -v s="$sess" \
        '!/^[[:space:]]*#/ && $1 == s { $1=""; $2=""; sub(/^[[:space:]]+/, ""); print; exit }' \
        "$MANIFEST_DIR/$srv.conf" 2>/dev/null)"
      [ -n "$startup" ] || return 0
      tmux -L "$srv" send-keys -t "$sess:" "$startup" Enter
      return 0
      ;;
  esac

  # Case 2: an editor sitting on a stale daily.
  [ "$cmd" = "nvim" ] || return 0
  title="$(tmux -L "$srv" display-message -p -t "$pane" '#{pane_title}' 2>/dev/null)"
  case "$title" in *"journal/daily"*) ;; *) return 0 ;; esac

  today="$(notes path daily 2>/dev/null)"
  [ -n "$today" ] && [ -f "$today" ] || return 0
  case "$title" in *"$(basename "$today")"*) return 0 ;; esac   # already today

  tmux -L "$srv" send-keys -t "$sess:" Escape
  tmux -L "$srv" send-keys -t "$sess:" ":e $today" Enter
}

# Two ways to arrive in a world, on purpose:
#
#   hop   resume where you left off  -> flip back and forth between two pieces of work
#   root  the world's landing page   -> "take me to the top of hub"
#
# hop is the one you want bound to a key you hit all day; root is the deliberate
# "start from the beginning" move.
_enter() {
  local target="${1:?needs a server name}" mode="${2:-last}"

  if [ -n "${TMUX:-}" ]; then
    # -E runs after this client detaches, so the two halves read as one motion.
    #
    # It MUST dispatch to `land`, not back to hop/root. tmux does NOT clear $TMUX
    # for the -E command — it stays set, pointing at the server you just left. So a
    # hop/root on the far side would see $TMUX, take this same branch, and recurse
    # instead of attaching: you end up detached, and the next `ensure` leaves a
    # stray session behind. `land` never looks at $TMUX.
    # $mode is quoted too: pick-all passes "<session>" or "<session>:<window>",
    # and a session name is free to contain spaces.
    tmux detach-client -E \
      "$(printf '%q' "$0") land $(printf '%q' "$target") $(printf '%q' "$mode")"
    return 0
  fi

  cmd_land "$target" "$mode"
}

# land <server> [last|root|<session>|<session>:<window>] -- the far side of a hop.
# Never consults $TMUX, because it is reached from `detach-client -E`, where $TMUX is
# still set to the OLD server.
cmd_land() {
  local target="${1:?land needs a server name}" mode="${2:-last}"

  cmd_ensure "$target" >/dev/null

  # An explicit target from pick-all. Anything that is not one of the two keywords
  # is a session name, optionally with a window after a colon.
  case "$mode" in
    last|root) ;;
    *)
      local want_sess="${mode%%:*}" want_win=""
      case "$mode" in *:*) want_win="${mode#*:}" ;; esac
      if tmux -L "$target" has-session -t "=$want_sess" 2>/dev/null; then
        # select-window before attaching: it sets the session's current window, so
        # the client opens on the row that was picked rather than wherever the
        # session was left.
        [ -n "$want_win" ] &&
          tmux -L "$target" select-window -t "$want_sess:$want_win" 2>/dev/null
        unset TMUX
        exec tmux -L "$target" attach -t "=$want_sess"
      fi
      # Picked a session that died between listing and landing — fall through to
      # resume rather than dumping the user on an error.
      mode=last
      ;;
  esac

  if [ "$mode" = "root" ]; then
    # The manifest's FIRST entry is the world's root page.
    local landing
    landing="$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' \
      "$MANIFEST_DIR/$target.conf" 2>/dev/null)"
    if [ -n "$landing" ] && tmux -L "$target" has-session -t "=$landing" 2>/dev/null; then
      _refresh_landing "$target" "$landing"
      # $TMUX is still set here (see _enter); attach refuses to nest while it is,
      # so drop it. -L already selects the server, so nothing else needs it.
      unset TMUX
      exec tmux -L "$target" attach -t "=$landing"
    fi
  fi

  # Resume: the most recently used session that is NOT the landing page.
  #
  # Two things had to be got right here.
  #
  # A bare `attach` is not good enough: tmux's documented rule is that it "will
  # prefer the most recently used UNATTACHED session", so a session that still has a
  # client on it — a second terminal, another window on the same world — gets
  # skipped and you land somewhere else. Pick explicitly by last_attached instead.
  #
  # And the landing page must be EXCLUDED. Visiting the root with N/M updates its
  # last_attached like any other visit, so a literal "most recent" reading sends you
  # back to the daily rather than to the work you were doing — resume felt random
  # because a quick N poisoned the next resume. Resume means "what I was working
  # on"; the root page is never that. Falls back to the landing (then to a plain
  # attach) when the world genuinely has nothing else.
  local landing_name last
  landing_name="$(awk '!/^[[:space:]]*#/ && NF {print $1; exit}' \
    "$MANIFEST_DIR/$target.conf" 2>/dev/null)"

  last="$(tmux -L "$target" list-sessions \
            -F '#{session_last_attached} #{session_name}' 2>/dev/null \
          | sort -rn | cut -d' ' -f2- \
          | grep -vxF "${landing_name:-}" | head -1)"

  # Nothing but the root in this world — go there rather than nowhere.
  [ -n "$last" ] || last="$landing_name"

  unset TMUX
  if [ -n "$last" ] && tmux -L "$target" has-session -t "=$last" 2>/dev/null; then
    exec tmux -L "$target" attach -t "=$last"
  fi
  exec tmux -L "$target" attach
}

cmd_hop()  { _enter "${1:?hop needs a server name}"  last; }
cmd_root() { _enter "${1:?root needs a server name}" root; }

# pick -- fzf over the SERVERS, sessions in the preview. The compact view: two rows,
# one per world, and you drill in only when you want to. Kept alongside pick-all
# because they answer different questions -- "which world" vs "where is that window".
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

# _all_rows -- every session, and every window inside it, across every LIVE server.
#
# This is the one view no other tool here can give you. choose-tree (Prefix+w) is
# server-scoped by construction, and sesh shells out to plain `tmux` so it follows
# $TMUX into whichever single server you are already in. Seeing hub and lab at once
# has to be assembled from outside both, which is what this does.
#
# There is no preview pane. Everything worth knowing is ON the row, because a preview
# only describes whatever the cursor happens to be sitting on -- you have to arrow
# through the list to learn what is in it. The list itself has to answer "what is this".
#
# Three levels, all selectable: server -> session -> window.
#
# Emits TAB-separated: <server> <session> <window-or-empty> <display>. fzf renders
# only field 4 (--with-nth=4) and the first three are the machine target. Kept
# separate from the fzf call so it can be tested without a terminal.
_all_rows() {
  local s sess wins att spath idx wname wact pcmd ptitle disp mark n what

  while IFS= read -r s; do
    [ -n "$s" ] || continue

    # The server itself, so one list replaces both this and the old server picker.
    n="$(session_count "$s")"
    printf '%s\t\t\t%s\n' "$s" "$(printf '%-4s %s session(s)' "$s" "$n")"

    while IFS=$'\t' read -r sess wins att spath; do
      [ -n "$sess" ] || continue

      # The simple explanation of a session: WHERE it is and WHAT is running in it.
      # Both are derived, so an ad-hoc session gets described as well as a declared
      # one and no manifest has to be kept in sync with this.
      spath="${spath/#$HOME/\~}"
      what="$(tmux -L "$s" list-panes -s -t "=$sess" -F '#{pane_current_command}' 2>/dev/null \
        | sort | uniq -c | sort -rn \
        | awk '{ printf "%s%s, ", $2, ($1 > 1 ? " x" $1 : "") }' | sed 's/, $//')"

      disp="$(printf '  %-13s %-22s %2s win  %s' "$sess" "$spath" "$wins" "$what")"
      [ "$att" = "1" ] && disp="$disp  (attached)"
      printf '%s\t%s\t\t%s\n' "$s" "$sess" "$disp"

      # One row per window. pane_current_command and pane_title resolve against the
      # window's ACTIVE pane, which is what makes these rows worth reading: the
      # command says what is running, the title is where a program puts its context
      # (claude puts the task there, nvim the filename).
      while IFS=$'\t' read -r idx wname wact pcmd ptitle; do
        [ -n "$idx" ] || continue
        mark=' '; [ "$wact" = "1" ] && mark='*'
        # Window names here are usually git branches, which run long enough to shove
        # every later column off screen. Truncate rather than let the row wrap.
        [ ${#wname} -gt 16 ] && wname="${wname:0:15}~"
        ptitle="${ptitle% - Nvim}"          # nvim suffixes every title; it says nothing
        disp="$(printf '      %2s%s %-16s %-8s %s' \
          "$idx" "$mark" "$wname" "$pcmd" "$ptitle")"
        printf '%s\t%s\t%s\t%s\n' "$s" "$sess" "$idx" "$disp"
      done < <(tmux -L "$s" list-windows -t "=$sess" -F \
        "#{window_index}"$'\t'"#{window_name}"$'\t'"#{window_active}"$'\t'"#{pane_current_command}"$'\t'"#{pane_title}" \
        2>/dev/null)

    done < <(tmux -L "$s" list-sessions -F \
      "#{session_name}"$'\t'"#{session_windows}"$'\t'"#{session_attached}"$'\t'"#{session_path}" 2>/dev/null)
  done < <(live_servers)
}

# pick-all -- fzf over every session and window everywhere. Enter goes there.
cmd_pick_all() {
  command -v fzf >/dev/null 2>&1 || die "fzf not installed"
  local rows choice srv sess win
  rows="$(_all_rows)"
  [ -n "$rows" ] || die "no tmux servers are running"

  # No --preview on purpose: the rows already say where each session is and what is
  # running in it, and a preview only describes the one row under the cursor.
  choice="$(printf '%s\n' "$rows" | fzf --reverse --border \
    --delimiter=$'\t' --with-nth=4 \
    --prompt='everywhere > ' \
    --header='Enter: go there · Esc: cancel')" || return 0
  [ -n "$choice" ] || return 0

  srv="$(printf '%s' "$choice" | cut -f1)"
  sess="$(printf '%s' "$choice" | cut -f2)"
  win="$(printf '%s' "$choice" | cut -f3)"

  [ -n "$srv" ] || return 0
  if [ -z "$sess" ]; then
    cmd_hop "$srv"                 # a server row: resume that world
  elif [ -n "$win" ]; then
    _enter "$srv" "$sess:$win"
  else
    _enter "$srv" "$sess"
  fi
}

main() {
  local verb="${1:-pick}"
  case "$verb" in
    ls|list)      cmd_ls ;;
    hop)          shift; cmd_hop "${1:-}" ;;
    root)         shift; cmd_root "${1:-}" ;;
    land)         shift; cmd_land "${1:-}" "${2:-last}" ;;
    ensure)       shift; cmd_ensure "${1:-}" ;;
    pick-session) cmd_pick_session ;;
    pick)         cmd_pick ;;
    pick-all)     cmd_pick_all ;;
    rows)         _all_rows ;;
    -h|--help)    sed -n '2,40p' "$0" ;;
    *)            cmd_hop "$verb" ;;   # `tmx hub` is the common case
  esac
}

# Sourced (by the test suite) rather than run: stop here with every function defined but
# `main` never invoked. The default arm of main's dispatch is `cmd_hop`, so without this
# guard sourcing the file would try to SWITCH the caller's tmux client.
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

main "$@"
