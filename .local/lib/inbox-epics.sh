# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather than a shebang.
#
# inbox-epics.sh: which epic a row the inbox agents write belongs to. The model picks a feature epic
# from the open ones, or names a new one, and code checks the pick, because `#of/` is not refused at
# write time: an id the model invents would sit on the row as a dangling parent until `notes doctor
# --projects` found it. A row left with no `#of/` goes under its system's standing epic, which
# `notes ptask` links (`~/.local/src/docs/lifecycle.md`, "What an epic is").

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

# new_epic_rule: the prompt text that lets an answer carry a new feature epic (epic_new files it).
new_epic_rule() {
  printf '%s' "When the work is a new capability the person could check by using it and no open epic covers it, the answer may carry \"epic\": \"epic(<system>): <that outcome, in the person's words>\", <system> being one of the project's systems; that epic is filed first, tagged #new, and the rows go under it. Never an epic for a fix, a chore or one small change."
}

# epic_new <project> <epic text>: file a model's new feature epic on the project's human sheet,
# tagged #new, and print its id; an open twin's id when it is already there. Nothing, and exit 1,
# when the text is not `epic(<system>): <outcome>` over one of the project's systems: the rows
# are then filed without it and `notes ptask` puts them under their standing epics. A dry run
# prints what it would run and exits 2.
epic_new() {
  local p="$1" text sys out rc=0
  text="$(sed -E 's/(^| )#[A-Za-z][A-Za-z0-9_/:.-]*//g; s/ +/ /g; s/^ //; s/ $//' <<<"$2")"
  [[ "$text" =~ ^epic\(([a-z][a-z0-9-]*)\):\ .+ ]] || return 1
  sys="${BASH_REMATCH[1]}"
  project-stage-check "$p" --list 2>/dev/null | cut -f1 | grep -qxF -- "$sys" || return 1
  if [ "${DRY:-0}" = 1 ]; then printf 'would run: notes ptask %q add -- %q\n' "$p" "$text #new" >&2; return 2; fi
  out="$(notes ptask "$p" add -- "$text #new" 2>&1)" || rc=$?
  [ "$rc" = 0 ] || [ "$rc" = 3 ] || return 1
  # A new epic prints its row; a twin is named on the refusal line. Either carries the id.
  sed -nE 's/.*epic\(.*<!--(.*[^a-z])?id:([a-z0-9]+-[0-9]+).*/\2/p' <<<"$out" | tail -n 1 | grep . || return 1
}

# under_epic <row> <id>: the row with `#of/<id>` added unless it names a parent already.
under_epic() {
  [[ " $1 " == *' #of/'* ]] && { printf '%s\n' "$1"; return; }
  printf '%s #of/%s\n' "$1" "$2"
}
