#!/usr/bin/env bash
# projects.sh - Prefix+P, the projects switcher. Every profile's projects in one small list,
# main ones first, with a count of their open work; Enter drops into a project's tasks.
#
# Usage: projects.sh [verb]
#
# Verbs:
#   (no verb)              open the switcher
#   --list [--drafts]      the project rows, TSV `profile name sheet label counts`, where
#                          label is the number, name and profile, the part search reads. Sorted prod,
#                          beta, alpha, unstaged, then by open count. Drafts only with --drafts.
#   --tasks <prof> <name>  the task rows of a project's current wave, TSV
#                          `path line key display`, urgent first
#   --header <prof> <name> the one-line count shown above the task rows
#   --key <view> <key>     the fzf action a key runs in a view (list|tasks). The keys mean one
#                          thing while you browse and type themselves while you search, so the
#                          choice is made here at keypress time, where a test can see it.
#   --help, -h             this text
#
# Keys, project list (it opens in hotkey mode, no input line):
#   1-9 / Enter  tasks      j k  move      /  search (Esc: leave the box, clear, quit)
#   o  open the sheet       n  new project d  show/hide drafts
#   s  set stage            x  archive     q / Esc  quit
#
# Keys, task view:
#   a  add (text, then priority)   m  move to another project (same profile)
#   x  done (asks for a proof ref) +  -  one wave sooner / later
#   o  open the sheet at the row   /  search      Esc  back to the projects
#
# Every write is a `notes` CLI call, so the CLI stays the only writer of a sheet or an index.
# The counts come from one `notes projects --stats` call. `o` opens in the nvim that opened
# the popup when PROJECTS_NVIM names its server socket (`<leader>np` passes it), else in this
# session's editor window (editor.sh open).

SELF="$(realpath "${BASH_SOURCE[0]}")"
. "${SELF%/*}/panel-lib.sh" || exit 1

PROJECTS_NVIM="${PROJECTS_NVIM:-}"
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
    # The profile is cut to 8 for DISPLAY only; column 1 stays whole because the task view
    # passes it to `notes --profile`.
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

# Display only: the priority word is read off the tag text, so a `#high` inside a code span
# reads as high here while `notes` (md::task_priority) would skip it. Sorting is all it feeds.
cmd_tasks() {
  local profile="$1" name="$2"
  notes --profile "$profile" ptask "$name" list | awk -F'\t' \
    -v E="$C_ERR" -v I="$C_INP" -v D="$C_DIM" -v B="$C_BOX" -v O="$C_OFF" '
    {
      t = $4
      wip = (t ~ /^[ \t]*- \[\/\]/)
      sub(/^[ \t]*- \[.\] /, "", t)
      p = 3; w = ""
      if (t ~ /#urgent/) { p = 0; w = E "urgent" O }
      else if (t ~ /#high/) { p = 1; w = I "high  " O }
      else if (t ~ /#low/) { p = 2; w = D "low   " O }
      else w = "      "
      gsub(/[ \t]*#(urgent|high|low|v[0-9]+\.[0-9]+\.[0-9]+)/, "", t)
      gsub(/[ \t]*<!--[^>]*-->/, "", t)
      printf "%d\t%06d\t%s\t%s\t%s\t%s %s%s\n", p, $2, $1, $2, $3, w, (wip ? B "~ " O : ""), t
    }' | sort -t "$PANEL_TAB" -k1,1n -k2,2n | cut -f3-
}

cmd_header() {
  local profile="$1" name="$2"
  notes projects --stats | awk -F'\t' -v p="$profile" -v n="$name" '
    $1 == p && $2 == n {
      s = sprintf("%s %s  %d open", n, $4, $5)
      if ($6 > 0) s = s sprintf("  %d urgent", $6)
      if ($7 > 0) s = s sprintf("  %d high", $7)
      if ($8 > 0) s = s sprintf("  %d low", $8)
      if ($9 > 0) s = s sprintf("  +%d planned", $9)
      if ($10 > 0) s = s sprintf("  agent %d", $10)
      print s
    }'
}

# --- Keys ---
# The fzf action for <key> in <view>, printed for a `transform:` bind. While the input is
# showing ($FZF_INPUT_STATE = enabled) a printable key types itself; otherwise it is a
# hotkey. Placeholders ({1}, {2}, {3}) are left for fzf to fill and quote, so a task's own
# text never has to survive being spliced into an action string.
#
# The list view's accept actions print a word first (`enter` or `open`) and then whether the
# drafts were showing, which is what cmd_pick reads back to know what to do next.
cmd_key() {
  local view="$1" key="$2" typing=0 drafts='' state=main
  [ "${FZF_INPUT_STATE:-}" = enabled ] && typing=1
  case "${FZF_PROMPT:-}" in all*) drafts=' --drafts' state=drafts ;; esac
  # After a write: the list reloads with the drafts as they were; the task view reloads its
  # rows and recounts its header. $PROJECTS_P/N are exported by _pick_tasks and expanded by
  # the shell fzf runs the action in, not here.
  local relist="reload($Q --list$drafts)"
  local retask="reload($Q --tasks \"\$PROJECTS_P\" \"\$PROJECTS_N\")+transform-header($Q --header \"\$PROJECTS_P\" \"\$PROJECTS_N\")"

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
    case "$view" in
    list) echo "print(enter)+print($state)+accept" ;;
    tasks) echo 'print(open)+accept' ;;
    esac
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
  list:[1-9]) echo "pos($key)+print(enter)+print($state)+accept" ;;
  list:o) echo "print(open)+print($state)+accept" ;;
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
  tasks:a) echo "execute($Q --task-add \"\$PROJECTS_P\" \"\$PROJECTS_N\")+$retask" ;;
  tasks:m) echo "execute($Q --task-move \"\$PROJECTS_P\" \"\$PROJECTS_N\" {3})+$retask" ;;
  tasks:x) echo "execute($Q --task-done \"\$PROJECTS_P\" \"\$PROJECTS_N\" {3})+$retask" ;;
  tasks:+) echo "execute-silent(notes --profile \"\$PROJECTS_P\" ptask \"\$PROJECTS_N\" promote {3})+$retask" ;;
  tasks:-) echo "execute-silent(notes --profile \"\$PROJECTS_P\" ptask \"\$PROJECTS_N\" demote {3})+$retask" ;;
  tasks:o) echo 'print(open)+accept' ;;
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

cmd_task_add() {
  local text prio
  text="$(_ask "$2 task: ")"
  [ -n "$text" ] || return 0
  prio="$(_choose 'priority > ' high urgent low)" || return 0
  _write notes --profile "$1" ptask "$2" add "$text #$prio"
}

# Same profile only: `ptask move --project` moves a row between sheets of one profile.
cmd_task_move() {
  local dest
  dest="$(_choose "move to > " $(notes --profile "$1" projects | cut -f1 | grep -vxF "$2"))" || return 0
  _write notes --profile "$1" ptask "$2" move --project "$dest" "$3"
}

cmd_task_done() {
  local proof
  proof="$(_ask 'proof (pr:N, run:ID, url; blank = none): ')"
  if [ -n "$proof" ]; then
    _write notes --profile "$1" ptask "$2" done --proof "$proof" "$3"
  else
    _write notes --profile "$1" ptask "$2" done --unverified "checked off by hand in the projects popup" "$3"
  fi
}

# --- Open ---
_open() {
  local file="$1" line="${2:-1}"
  if [ -n "$PROJECTS_NVIM" ] && [ -S "$PROJECTS_NVIM" ]; then
    nvim --server "$PROJECTS_NVIM" --remote-send "<C-\\><C-N>:e +$line ${file// /\\ }<CR>"
  else
    "$PANEL_DIR/editor.sh" open "$file" "$line"
  fi
}

# --- Picker ---
# Project search reads the label (number, name, profile) and never the counts: --nth counts
# the fields --with-nth shows, so the label is its own tab field and --tabstop=1 draws the
# tab as one space. Fuzzy over the whole row, "dodg" matched unity-playground through
# playgroun(d) (o)pen planne(d) a(g)ent. Task search is --exact for the same reason at
# sentence length.
_pick_tasks() {
  local out path line
  local -a BINDS
  export PROJECTS_P="$1" PROJECTS_N="$2"
  _binds tasks j k / a m x + - o esc enter
  out="$(cmd_tasks "$1" "$2" | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
    --no-input --with-nth=4 --exact --prompt="$2 > " \
    --header="$(cmd_header "$1" "$2")"$'\n'"a add  m move  x done  +/- wave  o open  / search  esc back" \
    "${BINDS[@]}")" || return 0
  [ "${out%%$'\n'*}" = open ] || return 0
  IFS="$PANEL_TAB" read -r path line _ <<<"${out#*$'\n'}"
  _open "$path" "$line"
  return 1
}

cmd_pick() {
  panel_need fzf notes
  panel_fzf_opts
  panel_fzf_table

  local out key state=main row profile name sheet prompt list
  local -a BINDS
  while :; do
    list='' prompt='projects> '
    if [ "$state" = drafts ]; then list=--drafts prompt='all projects> '; fi
    _binds list j k / 1 2 3 4 5 6 7 8 9 o q n s x d esc enter
    out="$(cmd_list ${list:+"$list"} | fzf "${PANEL_FZF_OPTS[@]}" "${PANEL_FZF_TABLE[@]}" \
      --no-input --with-nth=4,5 --nth=1 --tabstop=1 --prompt="$prompt" \
      --header='1-9 tasks  o open  n new  s stage  x archive  d drafts  / search  q quit' \
      "${BINDS[@]}")" || return 0
    key="$(sed -n 1p <<<"$out")"
    state="$(sed -n 2p <<<"$out")"
    row="$(sed -n 3p <<<"$out")"
    IFS="$PANEL_TAB" read -r profile name sheet _ <<<"$row"
    case "$key" in
    open)
      _open "$sheet" 1
      return 0
      ;;
    enter) _pick_tasks "$profile" "$name" || return 0 ;;
    *) return 0 ;;
    esac
  done
}

# --- The test seam ---
[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0

# --- Dispatch ---
case "${1:-}" in
'') cmd_pick ;;
--list) cmd_list "${2:-}" ;;
--tasks) cmd_tasks "${2:?profile}" "${3:?name}" ;;
--header) cmd_header "${2:?profile}" "${3:?name}" ;;
--key) cmd_key "${2:?view}" "${3:?key}" ;;
--new) panel_fzf_opts && cmd_new ;;
--stage) panel_fzf_opts && cmd_stage "${2:?profile}" "${3:?name}" ;;
--archive) cmd_archive "${2:?profile}" "${3:?name}" ;;
--task-add) panel_fzf_opts && cmd_task_add "${2:?profile}" "${3:?name}" ;;
--task-move) panel_fzf_opts && cmd_task_move "${2:?profile}" "${3:?name}" "${4:?task}" ;;
--task-done) cmd_task_done "${2:?profile}" "${3:?name}" "${4:?task}" ;;
-h | --help) panel_usage ;;
*) panel_die "unknown verb: $1 (try --help)" ;;
esac
