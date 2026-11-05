#!/usr/bin/env bash
# projects.sh - Prefix+p, the projects finder. Every profile's projects in one small list,
# main ones first, with a count of their open work; Enter opens the hub's Board tab on that
# project's rows, where tasks are added, moved, edited, rewaved and closed; e opens the
# project's sheet in the hub notes editor.
#
# Usage: projects.sh [verb]
#
# Verbs:
#   (no verb)              open the switcher
#   --list [--drafts]      the project rows, TSV `profile name sheet label counts`, where
#                          label is the number, name and profile, the part search reads. Sorted prod,
#                          beta, alpha, unstaged, then by open count. Drafts only with --drafts.
#   --board <prof> <name>  show the hub Board filtered to one project and go to its window
#   --key <view> <key>     the fzf action a key runs in a view (list). The keys mean one
#                          thing while you browse and type themselves while you search, so the
#                          choice is made here at keypress time, where a test can see it.
#   --help, -h             this text
#
# Keys, project list (it opens in hotkey mode, no input line):
#   1-9 / Enter / o  hub Board   j k  move   /  search (Esc: leave the box, clear, quit)
#   e  the sheet in the hub notes editor   n  new project   d  show/hide drafts
#   s  set stage            x  archive     q / Esc  quit
#
# A project's tasks live on the hub Projects tab (`hub tab projects <profile>/<name>`, then the
# hub window): its card on top, its rows below with the board's keys: add, start, done, move,
# edit, tags, a wave sooner or later, open the sheet at the row.
#
# Every write here is a `notes` CLI call, so the CLI stays the only writer of a sheet or an index.
# The counts come from one `notes projects --stats` call. `e` is `tmx open hub <sheet>`: the
# hub world's landing nvim (~/.notes), wherever the popup was opened from.

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

PROJECTS_STAGES="${PROJECTS_STAGES:-draft alpha beta prod}"

Q="$(printf '%q' "$SELF")"

# --- Rows ---
# One counts segment: "85 open  1 urgent  56 high  22 low  +1 planned  agent 228". A zero is
# left out, so a quiet project reads quiet instead of as a row of zeros.
cmd_list() {
  local drafts=0
  [ "${1:-}" = --drafts ] && drafts=1
  notes projects --stats | awk -F'\t' -v drafts="$drafts" '
    function rank(s) { return s == "prod" ? 0 : s == "beta" ? 1 : s == "alpha" ? 2 : s == "" ? 3 : 4 }
    $3 == "draft" && !drafts { next }
    { printf "%d\t%09d\t%s\n", rank($3), 999999999 - $5, $0 }
  ' | sort -t "$PANEL_TAB" -k1,1n -k2,2 | cut -f3- | awk -F'\t' \
    -v H="$C_HEAD" -v D="$C_DIM" -v A="$C_ACC" -v E="$C_ERR" -v I="$C_INP" -v O="$C_OFF" '
    # The profile is cut to 8 for DISPLAY only; column 1 stays whole because the writes
    # and the Board search pass it on.
    { row[NR] = $0; if (length($2) > w) w = length($2); if (length(substr($1, 1, 8)) > pw) pw = length(substr($1, 1, 8)) }
    END {
      for (i = 1; i <= NR; i++) {
        split(row[i], f, "\t")
        n = (i <= 9) ? i : " "
        c = (f[5] > 0) ? sprintf("%d open", f[5]) : D "clear" O
        if (f[6] > 0) c = c sprintf("  %s%d urgent%s", E, f[6], O)
        if (f[7] > 0) c = c sprintf("  %s%d high%s", I, f[7], O)
        if (f[8] > 0) c = c sprintf("  %s%d low%s", D, f[8], O)
        if (f[9] > 0) c = c sprintf("  +%d planned", f[9])
        if (f[10] > 0) c = c sprintf("  %sagent %d%s", D, f[10], O)
        printf "%s\t%s\t%s\t%s %s%-*s%s  %s%-*s%s\t%-8s %s%-5s%s  %s\n", f[1], f[2], f[11],
          n, H, w, f[2], O, D, pw, substr(f[1], 1, 8), O, f[4], A, f[3], O, c
      }
    }'
}

# --- Keys ---
# The fzf action for <key> in <view>, printed for a `transform:` bind. While the input is
# showing ($FZF_INPUT_STATE = enabled) a printable key types itself; otherwise it is a
# hotkey. Placeholders ({1}, {2}, {3}) are left for fzf to fill and quote, so a project's own
# name never has to survive being spliced into an action string.
#
# The accept actions print a word (`enter` or `edit`) above the row, which is what cmd_pick
# reads back to know what to do.
cmd_key() {
  local view="$1" key="$2" typing=0 drafts='' state=main
  [ "${FZF_INPUT_STATE:-}" = enabled ] && typing=1
  case "${FZF_PROMPT:-}" in all*) drafts=' --drafts' state=drafts ;; esac
  # After a write the list reloads with the drafts as they were.
  local relist="reload($Q --list$drafts)"

  # Esc steps out one layer at a time: leave the search box keeping its results (so a
  # hotkey can act on the row you searched for), then clear the filter, then quit or go
  # back. See _binds for why clearing is split across esc and esc-after.
  if [ "$key" = esc ]; then
    if [ "$typing" = 1 ]; then
      echo hide-input
    elif [ -n "${FZF_QUERY:-}" ]; then
      echo show-input
    else
      echo abort
    fi
    return 0
  fi
  if [ "$key" = esc-after ]; then
    if [ "$typing" = 1 ]; then echo hide-input; else echo ignore; fi
    return 0
  fi
  if [ "$key" = enter ]; then
    echo "print(enter)+accept"
    return 0
  fi
  # Printable keys type themselves while searching.
  if [ "$typing" = 1 ]; then
    echo "put($key)"
    return 0
  fi

  case "$view:$key" in
  *:j) echo down ;;
  *:k) echo up ;;
  *:/) echo show-input ;;
  list:[1-9]) echo "pos($key)+print(enter)+accept" ;;
  list:o) echo 'print(enter)+accept' ;;
  list:e) echo 'print(edit)+accept' ;;
  list:q) echo abort ;;
  list:n) echo "execute($Q --new)+$relist" ;;
  list:s) echo "execute($Q --stage {1} {2})+$relist" ;;
  list:x) echo "execute($Q --archive {1} {2})+$relist" ;;
  list:d)
    if [ "$state" = drafts ]; then
      echo "change-prompt(projects> )+reload($Q --list)"
    else
      echo "change-prompt(all projects> )+reload($Q --list --drafts)"
    fi
    ;;
  *) echo ignore ;;
  esac
}

# Sets BINDS to the --bind arguments routing every listed key through cmd_key for <view>.
# An array, never word-split output: each bind holds spaces (`--key list j`), and the sandbox
# path holds one by design.
_binds() {
  local view="$1" k
  shift
  BINDS=()
  for k in "$@"; do
    case "$k" in
    # Esc is a chain, not one transform, because fzf 0.74 ignores a query edit while the
    # input is hidden and applies a transform's answer as one batch: `clear-query` from
    # inside the transform never lands. So the transform (esc) shows the input when there
    # is a filter to clear, the bare clear-query runs, and esc-after hides it again. While
    # typing, esc hides the input first and the clear-query is ignored, which is what keeps
    # the filter for a hotkey to act on.
    esc) BINDS+=("--bind=esc:transform($Q --key $view esc)+clear-query+transform($Q --key $view esc-after)") ;;
    *) BINDS+=("--bind=$k:transform:$Q --key $view $(printf '%q' "$k")") ;;
    esac
  done
}

# --- Writes (run inside the popup via fzf execute, so they own the terminal) ---
# Run a `notes` write; on failure show why and wait, so the error is read before the list
# redraws over it.
_write() {
  local out
  if ! out="$("$@" 2>&1)"; then
    printf '%s\n%s\n' "$*" "$out"
    read -rsn1 -p 'press a key '
    return 1
  fi
}

_ask() { # _ask <prompt> -> the trimmed answer on stdout
  local a
  read -rp "$1" a
  a="${a#"${a%%[![:space:]]*}"}"
  printf '%s' "${a%"${a##*[![:space:]]}"}"
}

_choose() { # _choose <prompt> <choices...> -> the one picked
  printf '%s\n' "${@:2}" | fzf "${PANEL_FZF_OPTS[@]}" --no-sort --prompt="$1"
}

cmd_new() {
  local profile name
  profile="$(_choose 'new project in > ' $(notes config --profiles))" || return 0
  name="$(_ask "$profile project name: ")"
  [ -n "$name" ] || return 0
  _write notes --profile "$profile" projects --new "$name"
}

cmd_stage() {
  local stage
  # shellcheck disable=SC2086 # the stage list is a word list on purpose
  stage="$(_choose "$2 stage > " $PROJECTS_STAGES)" || return 0
  _write notes --profile "$1" projects --stage "$2" --set "$stage"
}

cmd_archive() {
  [ "$(_ask "archive $1/$2? [y/N] ")" = y ] || return 0
  _write notes --profile "$1" projects --archive "$2"
}

# --- Board ---
# The hub's Projects tab, opened on the project's rows. `hub tab` reaches a running hub over
# its socket, else the next hub to start takes the request.
cmd_board() {
  panel_need hub tmx
  hub tab projects "$1/$2" && tmx goto hub hub:board
}

# --- Picker ---
# The table flags minus --no-sort. An empty query shows the rows in their own order either
# way; a search ranks by match, which is what makes "time" land on time-tangle rather than
# on agent-run(time), the earlier row a scattered match also hits. Ties keep row order.
PROJECTS_FZF_TABLE=(--cycle --wrap --tiebreak=index --delimiter="$PANEL_TAB")

# Project search reads the label (number, name, profile) and never the counts: --nth counts
# the fields --with-nth shows, so the label is its own tab field and --tabstop=1 draws the
# tab as one space. Fuzzy over the whole row, "dodg" matched unity-playground through
# playgroun(d) (o)pen planne(d) a(g)ent.
cmd_pick() {
  panel_need fzf notes
  panel_fzf_opts

  local out profile name sheet
  local -a BINDS
  _binds list j k / 1 2 3 4 5 6 7 8 9 o e q n s x d esc enter
  out="$(cmd_list | fzf "${PANEL_FZF_OPTS[@]}" "${PROJECTS_FZF_TABLE[@]}" \
    --no-input --with-nth=4,5 --nth=1 --tabstop=1 --prompt='projects> ' \
    --header='1-9/o board  e notes  n new  s stage  x archive  d drafts  / search  q quit' \
    "${BINDS[@]}")" || return 0
  IFS="$PANEL_TAB" read -r profile name sheet _ <<<"${out#*$'\n'}"
  case "${out%%$'\n'*}" in
  edit) panel_need tmx && tmx open hub "$sheet" 1 ;;
  enter) cmd_board "$profile" "$name" ;;
  esac
}

# --- The test seam ---
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# --- Dispatch ---
case "${1:-}" in
'') cmd_pick ;;
--list) cmd_list "${2:-}" ;;
--board) cmd_board "${2:?profile}" "${3:?name}" ;;
--key) cmd_key "${2:?view}" "${3:?key}" ;;
--new) panel_fzf_opts && cmd_new ;;
--stage) panel_fzf_opts && cmd_stage "${2:?profile}" "${3:?name}" ;;
--archive) cmd_archive "${2:?profile}" "${3:?name}" ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
