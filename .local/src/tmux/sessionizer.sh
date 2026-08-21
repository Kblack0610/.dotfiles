#!/usr/bin/env bash
# sessionizer.sh - pick a repo or a worktree and land in a session named after it.
#
# Usage: sessionizer.sh [dir | verb]
#
#   (no args)     pick with fzf, then switch to (or create) that directory's session
#   <dir>         skip the picker and go straight there -- ANY directory, listed or not
#   --list        the candidate rows, one per line. Assertable without a terminal.
#   --name <dir>  the session name that <dir> would produce
#   --route <dir> "<world> <session>" if a manifest declares <dir>, else "here <name>"
#   -h, --help    this text
#
# The list is repos + manifest-declared dirs + worktrees, NOT every directory under the roots:
# a session name is a basename, so a deep walk produced colliding names (`dotfiles` x5) and
# still never reached ~/.worktrees. An arbitrary path is Prefix+S's job (sesh + zoxide).
#
# Row sources and the config keys (SESSIONIZER_ROOTS / _PRUNE / _DEPTH, WT_ROOT,
# TMUX_SERVERS_DIR): README.md, "Projects and worktrees (Prefix+f)". The world-routing rule:
# same file, "Which world a directory belongs to".

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

# Colon-separated, not space-separated, because these are PATHS and a directory may contain a
# space -- which the space-delimited form simply cannot express. That is not hypothetical: it
# is the documented limitation of .config/tmux-servers/*.conf (README: "the manifest is
# whitespace-delimited, so a session directory containing a space cannot be expressed there"),
# and the first draft of this file reintroduced it. The test sandbox's path contains a space by
# design, which is what caught it.
IFS=: read -r -a ROOTS <<< "${SESSIONIZER_ROOTS:-$HOME/dev:$HOME/bin:$HOME/src:$HOME/.dotfiles:$HOME/.dotfiles-private:$HOME/.notes}"
IFS=: read -r -a PRUNE <<< "${SESSIONIZER_PRUNE:-.git:.github:.serena:node_modules:.venv:venv:__pycache__:build:dist:target:out:.next:.cache:.npm:.cargo:.pytest_cache:.idea:.vscode:.vs:.DS_Store:.tmp:.temp}"
# How deep to look FOR A REPO under a root, not how deep a row may be: the walk stops at the
# outermost repo it finds either way.
SESSIONIZER_DEPTH="${SESSIONIZER_DEPTH:-4}"
# Shared with worktree.sh, which owns worktrees and puts them here. Same env key, so pointing
# one at a fixture points both.
WT_ROOT="${WT_ROOT:-$HOME/.worktrees}"
# The same default servers.sh uses, and overridable for the same reason: the tests point it
# at a fixture directory.
MANIFEST_DIR="${TMUX_SERVERS_DIR:-$HOME/.config/tmux-servers}"

# session_name <dir> -- the session this directory lands in. panel-lib owns the rule
# (leading dot stripped, interior dots folded); this is the `--name` verb's front door.
session_name() { panel_session_name "$1"; }

# manifest_rows -- "<world> <session> <dir>" for every session the manifests declare.
#
# Reads the manifests directly rather than asking tmux, because the question is "where does
# this directory BELONG", not "what is running" -- and the answer must be the same whether
# that world is up, down, or has never been booted on this machine.
#
# The parse is deliberately servers.sh:cmd_ensure's, down to the `~` expansion and skipping
# comments: two readers of one file that disagree about its format are a bug waiting for the
# first unusual line. Same whitespace-delimited limitation, too -- a manifest cannot express a
# directory containing a space, which is why nothing here tries to.
#
# ONE parse for two callers, which ask opposite questions of the same file: declared_by asks
# who owns a directory, declared_dirs asks which directories are named at all.
manifest_rows() {
  local f world name mdir cmd
  for f in "$MANIFEST_DIR"/*.conf; do
    [ -r "$f" ] || continue # an unmatched glob stays literal; -r rejects it
    world="${f##*/}"
    world="${world%.conf}"
    while read -r name mdir cmd; do
      case "$name" in '' | '#'*) continue ;; esac
      [ -n "$mdir" ] || continue
      mdir="${mdir/#\~/$HOME}"
      printf '%s %s %s\n' "$world" "$name" "${mdir%/}"
    done < "$f"
  done
  return 0
}

# declared_by <dir> -- "<world> <session>" for a directory some manifest names, rc 1 if none.
declared_by() {
  local dir="${1%/}" world name mdir
  while read -r world name mdir; do
    [ "$mdir" = "$dir" ] || continue
    printf '%s %s\n' "$world" "$name"
    return 0
  done < <(manifest_rows)
  return 1
}

# declared_dirs -- the manifests' own directories, when they exist on this machine.
#
# Not redundant with repo_roots: a declared directory can sit INSIDE a repo (~/.notes/lab is a
# subdirectory of the ~/.notes repo, and had its own keybind before this picker existed), or be
# a repo this machine has never cloned. The manifest is the routing table, so whatever it names
# is by definition somewhere this setup expects to work.
declared_dirs() {
  local world name dir
  while read -r world name dir; do
    [ -d "$dir" ] && printf '%s\n' "$dir"
  done < <(manifest_rows)
  return 0
}

# current_world -- the socket this client is on (`hub`), or nothing outside tmux.
#
# The socket basename, which is how servers.sh:cmd_pick_session already asks. `default` is
# the unnamed server and is nobody's world, so it is reported as such: a directory declared
# in hub.conf, picked from the default socket, should still go to hub.
current_world() {
  local sock
  panel_in_tmux || return 1
  sock="$(tmux display-message -p '#{socket_path}' 2>/dev/null)" || return 1
  sock="${sock##*/}"
  [ -n "$sock" ] && [ "$sock" != default ] && printf '%s\n' "$sock"
}

# route <dir> -- "<world> <session>", where world is `here` for anything undeclared.
cmd_route() {
  local dir="$1" decl
  if decl="$(declared_by "$dir")"; then
    printf '%s\n' "$decl"
  else
    printf 'here %s\n' "$(session_name "$dir")"
  fi
}

# repo_roots <root>... -- every git repo under these roots, OUTERMOST ONLY.
#
# Outermost is what makes the prune list short: submodules and vendored checkouts
# (tests/vendor/bats-core, .local/src/gungan) are real repos that nobody opens a session on,
# and they drop out because the repo above them was found first.
#
# The filter needs its input SORTED AFTER the /.git suffix is stripped, not before: a proper
# prefix always sorts ahead of the longer string, so stripped paths put every parent before its
# children. Sorting the `.git` paths instead breaks that (`/a/.config/x/.git` sorts before
# `/a/.git`, so the inner repo is kept and the outer one survives beside it).
repo_roots() {
  local prune_expr=() p dir k keep=() nested
  for p in "${PRUNE[@]}"; do prune_expr+=(-name "$p" -o); done
  unset "prune_expr[${#prune_expr[@]}-1]"

  # The `.git` clause comes FIRST and prunes itself: find takes the leftmost match, so a
  # `.git` in the prune list (it is there, and has to stay there for the descent) can no
  # longer swallow the very thing being searched for. Depth is +1 because a repo allowed to
  # sit DEPTH below a root keeps its .git one level deeper still.
  while IFS= read -r dir; do
    nested=
    for k in "${keep[@]}"; do
      case "$dir" in "$k"/*) nested=1 && break ;; esac
    done
    [ -n "$nested" ] || keep+=("$dir")
  done < <(find "$@" -maxdepth "$((SESSIONIZER_DEPTH + 1))" \
    -name .git -print -prune -o \
    \( "${prune_expr[@]}" \) -prune 2>/dev/null | sed 's|/\.git$||' | LC_ALL=C sort -u)

  [ "${#keep[@]}" -eq 0 ] || printf '%s\n' "${keep[@]}"
  return 0
}

# worktree_dirs -- the worktrees parked under $WT_ROOT.
#
# Reads the filesystem rather than shelling out to `wt --list`: a picker must not need another
# panel on PATH, and that verb runs git per row to report branch and state, none of which a
# path list uses. Only $WT_ROOT, deliberately -- worktrees belong in one place, and a stray
# checkout elsewhere is not something to advertise as a session.
#
# A linked worktree's `.git` is a FILE (a gitdir: pointer) where a main checkout's is a
# directory, so that one test both finds worktrees and rejects whatever else was parked here.
# worktree.sh:wt_is_linked is the fuller version of the same rule.
worktree_dirs() {
  local d
  for d in "$WT_ROOT"/*/; do
    d="${d%/}"
    [ -f "$d/.git" ] && printf '%s\n' "$d"
  done
  return 0
}

cmd_list() {
  local roots=() r
  for r in "${ROOTS[@]}"; do [ -d "$r" ] && roots+=("$r"); done
  # No existing root is not "no results" -- it means the config is wrong, and a picker that
  # opens empty looks identical to one whose search legitimately found nothing.
  [ "${#roots[@]}" -gt 0 ] || panel_fail "none of the configured roots exist: ${ROOTS[*]}" || return 1

  # A declared directory is usually a repo too, and a worktree of a repo under a root is not,
  # so the sources overlap in one direction only. Dedupe keeps first-seen order.
  {
    repo_roots "${roots[@]}"
    declared_dirs
    worktree_dirs
  } | awk '!seen[$0]++'
}

cmd_pick() {
  panel_need fzf
  panel_fzf_opts
  cmd_list | fzf "${PANEL_FZF_OPTS[@]}" --prompt='directory > '
}

# go <dir> -- ensure the session exists, then land in it.
#
# Replaces a `pgrep tmux` probe plus a bare `switch-client`. That pair had a real hole: run
# from a plain shell while a server happened to be up, it created the session detached and then
# called switch-client with no client attached, which fails. panel_focus_session branches on
# $TMUX, which is the actual question, so the pgrep goes away.
go() {
  local dir="$1" world name
  [ -d "$dir" ] || panel_die "not a directory: $dir"
  read -r world name <<< "$(cmd_route "$dir")"

  # Declared, and it lives somewhere else: hand the hop to tmx, which owns crossing worlds
  # (detach-client -E, the back-crumb, and `ensure` on the far side). `goto` and not `land`
  # -- land is the far side and would skip the detach; see servers.sh:_enter.
  #
  # This is reached from inside a display-popup, which is fine and is not new: Prefix+A
  # (`tmx pick-all`) is a popup that hops worlds exactly this way.
  if [ "$world" != here ] && [ "$world" != "$(current_world)" ]; then
    panel_need tmx
    exec tmx goto "$world" "$name"
  fi

  panel_ensure_session "$name" "$dir"
  panel_focus_session "$name"
}

[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

case "${1:-}" in
--list) cmd_list ;;
--name)
  [ $# -eq 2 ] || panel_die "--name needs a directory"
  session_name "$2"
  ;;
--route)
  [ $# -eq 2 ] || panel_die "--route needs a directory"
  cmd_route "$2"
  ;;
-h | --help) panel_usage ;;
'')
  selected="$(cmd_pick)" || exit 1
  [ -n "$selected" ] || exit 0 # cancelled the picker; not an error
  go "$selected"
  ;;
-*) panel_die "unknown verb: $1 (try --help)" ;;
*) go "$1" ;;
esac
