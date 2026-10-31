# shellcheck shell=bash
# This file is SOURCED, never executed. One reader for a plan's `## Phases` checklist, used by
# fleet-sessions (live sessions) and ask-sweep (plans whose session has gone).

# plan_phases <plan file> -> "done \t total \t first unchecked", from the `## Phases`
# checklist: `- [x]` landed and `- [-]` deferred count as done, `- [ ]` does not. Only
# unindented items are phases; an indented item is a step inside one. A missing file, no
# such section, or a section with no checklist lines prints "- \t - \t -".
plan_phases() {
  local out=""
  [ -f "$1" ] && out="$(awk '
    /^## / { inp = ($0 ~ /^## Phases([[:space:]]|$)/); next }
    !inp { next }
    /^[-*] \[[xX-]\] / { d++; t++; next }
    /^[-*] \[ \] / {
      t++
      if (nx == "") { nx = $0; sub(/^[-*] \[ \] /, "", nx); gsub(/\t/, " ", nx) }
    }
    END { if (t) printf "%d\t%d\t%s\n", d, t, (nx == "" ? "-" : nx) }' "$1")"
  if [ -n "$out" ]; then printf '%s\n' "$out"; else printf -- '-\t-\t-\n'; fi
}
