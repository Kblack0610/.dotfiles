# shellcheck shell=bash
# agent-pane.sh - the guard in front of a scripted line typed into a Claude pane by target.
# Typing itself is `agent-panel send`'s alone; this only decides whether there is exactly one
# pane to type into. Sourced by agent-request (send --session) and agent-voice.

# pane_one <where> <rows>: ROWS are the `agent-panel list --json` lines that match one target,
# WHERE names that target for the human. Sets PANE to the one row's pane and returns 0.
# Otherwise it sets nothing: it says why on stderr, prints the candidates as
# `pane<TAB>target<TAB>doing` on stdout when there are several, and returns 2. A session in a
# dialog (status waiting) is refused too, since a line typed there answers the dialog.
pane_one() {
  local where=$1 rows=$2 count who=${0##*/}
  # shellcheck disable=SC2034  # PANE is the caller's result
  PANE=''
  count=$(grep -c . <<<"$rows" || true)
  if [ "$count" -eq 0 ]; then
    echo "$who: no live Claude session in $where" >&2
    return 2
  fi
  if [ "$count" -gt 1 ]; then
    echo "$who: $count Claude sessions in $where; pick one" >&2
    jq -r '[.pane, .target, (.doing // "")] | @tsv' <<<"$rows"
    return 2
  fi
  if [ "$(jq -r .status <<<"$rows")" = waiting ]; then
    echo "$who: the session in $where is in a dialog; answer it, then send again" >&2
    return 2
  fi
  # shellcheck disable=SC2034
  PANE=$(jq -r .pane <<<"$rows")
}
