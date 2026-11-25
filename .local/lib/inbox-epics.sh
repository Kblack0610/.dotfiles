# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather than a shebang.
#
# inbox-epics.sh: which epic a row the inbox agents write belongs to. The model picks a feature epic
# from the open ones, or names a new one, and code checks the pick, because `#of/` is not refused at
# write time: an id the model invents would sit on the row as a dangling parent until `notes doctor
# --projects` found it. A row left with no `#of/` goes under its system's standing epic, which
# `notes ptask` links (`~/.local/src/docs/lifecycle.md`, "What an epic is").
# It also holds read_board, the one board read both inbox runners make.

# epics_open <board json>: `id<TAB>project<TAB>title` for every open epic.
epics_open() {
  jq -r '.rows[] | select(.type == "epic" and .state != "done" and .id != null)
    | "\(.id)\t\(.project)\t\(.text)"' <<<"$1" | cut -c1-160
}

# epics_of <project> <epics>: the lines of `epics_open` that are this project's.
epics_of() { awk -F'\t' -v p="$1" '$2 == p' <<<"$2"; }

# epic_known <id> <project> <epics>: is this an open epic of the project?
epic_known() { [ -n "$1" ] && epics_of "$2" "$3" | cut -f1 | grep -qxF -- "$1"; }

# epic_checked <row> <project> <epics>: the row with any `#of/` off it that names no open epic of
# the project. The row is the person's words, so a bad pick costs the tag and never the row.
epic_checked() {
  local w out=() words
  read -r -a words <<<"$1"
  for w in "${words[@]}"; do
    [[ "$w" == '#of/'* ]] && ! epic_known "${w#\#of/}" "$2" "$3" && continue
    out+=("$w")
  done
  printf '%s\n' "${out[*]}"
}

# systems_of <project>...: one `<project>: <id>, <id> (also: <alias>=<id>, ...)` line per project
# that has a system list (`project-stage-check --list`, the vocabulary `notes ptask` links by);
# nothing for one that has none, whose rows then take a free area word.
systems_of() {
  local p
  for p in "$@"; do
    project-stage-check "$p" --list 2>/dev/null | awk -F'\t' -v p="$p" '
      { ids = ids (ids == "" ? "" : ", ") $1
        n = split($3, a, ","); for (i = 1; i <= n; i++) if (a[i] != "") al = al (al == "" ? "" : ", ") a[i] "=" $1 }
      END { if (ids != "") print p ": " ids (al == "" ? "" : " (also: " al ")") }'
  done
}

# untagged <text>: the words without their hashtags (`#p:`, `#from/`, a priority), one space apart.
untagged() { sed -E 's/(^| )#[A-Za-z][A-Za-z0-9_/:.-]*//g; s/ +/ /g; s/^ //; s/ $//' <<<"$1"; }

# epic_new <project> <epic text>: file a model's new feature epic on the project's human sheet,
# tagged #new, and print its id; an open twin's id when it is already there. Nothing, and exit 1,
# when the text is not `epic(<system>): <outcome>` or `notes` refuses it (no such system, a
# standing title): the rows are then filed without it and `notes ptask` puts them under their
# standing epics. A dry run prints what it would run and exits 2. Run in the caller's shell (not
# `$(...)`), it leaves EPIC_TWIN=1 when the id is an open twin's, and EPIC_WHY the reason for an exit 1.
epic_new() {
  local p="$1" text out rc=0
  EPIC_TWIN="" EPIC_WHY=""
  text="$(untagged "$2")"
  [[ "$text" =~ ^epic\(([a-z][a-z0-9-]*)\):\ .+ ]] || { EPIC_WHY="not epic(<system>): <outcome>"; return 1; }
  if [ "${DRY:-0}" = 1 ]; then printf 'would run: notes ptask %q add -- %q\n' "$p" "$text #new" >&2; return 2; fi
  # The add runs as inbox-triage (a direct filer) whatever pass or session started it, so `notes`
  # checks the system against `project-stage-check <p> --list` and files the epic directly.
  out="$(AGENTCTL_NAME=inbox-triage AGENT_QUEUE_ITEM='' CLAUDE_CODE_SESSION_ID='' notes ptask "$p" add -- "$text #new" 2>&1)" || rc=$?
  if [ "$rc" != 0 ] && [ "$rc" != 3 ]; then
    EPIC_WHY="$(grep . <<<"$out" | tail -n 1 | sed 's/^Error: //' | cut -c1-160)"
    EPIC_WHY="${EPIC_WHY:-notes exited $rc}"
    return 1
  fi
  [ "$rc" = 3 ] && EPIC_TWIN=1
  # A new epic prints its row; a twin is named on the refusal line. Either carries the id.
  sed -nE 's/.*epic\(.*<!--(.*[^a-z])?id:([a-z0-9]+-[0-9]+).*/\2/p' <<<"$out" | tail -n 1 | grep . \
    || { EPIC_WHY="notes printed no epic id"; return 1; }
}

# under_epic <row> <id>: the row with `#of/<id>` added unless it names a parent already.
under_epic() {
  [[ " $1 " == *' #of/'* ]] && { printf '%s\n' "$1"; return; }
  printf '%s #of/%s\n' "$1" "$2"
}

# epic_standing <id> <project> <epics>: is this an open standing epic of the project, the one
# `notes ptask` links a row to by its area (`<system> to standard`)?
epic_standing() { epics_of "$2" "$3" | awk -F'\t' -v id="$1" '$1 == id && tolower($3) ~ / to standard$/ { f = 1 } END { exit !f }'; }

# reparent_args <project> <current parent> <epic> <epics>: the `notes ptask tag` options that put a
# row under <epic>, one a line, or nothing (exit 1) when it stays where it is. `tag` is the one verb
# that re-parents: `edit` keeps a row's `#of/` and refuses a `--text` naming another (#3267). An
# unparented row takes any open epic of its project. A row under its standing epic moves only to a
# feature epic, since the area already chose the standing one. A row under a feature epic, or under a
# row that is not an epic (a planned row's split), keeps its parent: someone chose it.
reparent_args() {
  local p="$1" cur="$2" new="$3" epics="$4"
  [ -n "$new" ] && [ "$new" != "$cur" ] && epic_known "$new" "$p" "$epics" || return 1
  if [ -n "$cur" ]; then
    epic_standing "$cur" "$p" "$epics" && ! epic_standing "$new" "$p" "$epics" || return 1
    printf '%s\n' --remove "of/$cur"
  fi
  printf '%s\n' --add "of/$new"
}

# parent_word <text>: the id of the last `#of/<id>` in the words, or nothing.
parent_word() { grep -oE '(^| )#of/[^ ]+' <<<"$1" | tail -n 1 | sed 's/.*#of\///'; }

# no_parent <text>: the words without any `#of/` tag, one space apart.
no_parent() { sed -E 's/(^| )#of\/[^ ]+//g; s/  +/ /g; s/^ //; s/ $//' <<<"$1"; }

# own_parent <line> <project> <board json>: the id the line's own last `#of/<id>` names, when that is
# an open row of the project, epic or not; nothing (exit 1) otherwise. The writer chose it: a session
# splitting an L row files its children under that row, and the model, told to pick only epics, would
# drop the link (epic_checked strips any non-epic), leaving the L row looking unsplit to dispatch.
own_parent() {
  local id
  id="$(parent_word "$1")"
  [ -n "$id" ] && jq -e --arg id "$id" --arg p "$2" \
    'any(.rows[]?; .id == $id and .project == $p and .state != "done")' >/dev/null <<<"$3" || return 1
  printf '%s\n' "$id"
}

# read_board: `notes board --json` into BOARD, which holds the board only when it returns 0. A
# failed read puts notes' own first error line and exit code in the log (the caller's say) and the
# pass's reason (proof_why), so the red it raises names its cause.
read_board() {
  local err rc why
  err="$(mktemp)"
  BOARD="$(notes board --json 2>"$err")"; rc=$?
  if [ "$rc" != 0 ]; then
    why="$(grep -m1 '[^[:space:]]' "$err" | clean 120)"
    why="notes board --json failed (exit $rc)${why:+: $why}"
    say "$why"; proof_why "$why"
  fi
  rm -f -- "$err"
  return "$rc"
}
