# shellcheck shell=bash
# This file is SOURCED, never executed, so it carries a shell directive rather than a shebang.
#
# inbox-epics.sh: which epic a row the inbox agents write belongs to. The model picks from the open
# epics and code checks the pick, because `#of/` is not refused at write time: an id the model
# invents would sit on the row as a dangling parent until `notes doctor --projects` found it.

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
