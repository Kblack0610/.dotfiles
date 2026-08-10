# shellcheck shell=bash
# This file is SOURCED, never executed (SC2148).
#
# scrub.sh -- remove every environment variable that can redirect an agent's
# TRANSPORT, before anything reads the environment.
#
# The role contract answers "what may this agent do". It never answered "whose
# wire, whose money, whose data" -- and of the raw call sites this replaced, six
# silently INHERITED transport from whatever last touched the shell, including
# the two runners that read the personal notes vault. An inherited
# ANTHROPIC_BASE_URL is not a configuration; it is an accident that looks like one.
#
# UNCONDITIONAL. Not "only when a route is chosen", not "only for gateway
# routes". A conditional scrub is one whose condition is eventually wrong, and
# the failure is silent egress. Generalises the single defensive scrub that
# ask-resume:55 had been doing alone.
#
# The classification lives in scrub.list as DATA so a test can assert it is a
# superset of every such name in the tree. See that file for why each entry is
# where it is.

# scrub_list_file -> path to the classification, or empty if unreadable.
scrub_list_file() {
  local f="${AGENTCTL_SCRUB_LIST:-${SELF_DIR:-}/lib/scrub.list}"
  [ -r "$f" ] && printf '%s' "$f"
}

# scrub_names <section> -> the NAMES in that section, one per line.
# Strips inline comments and blank lines; sections are [scrub] / [not-transport].
scrub_names() {
  local want="$1" f; f="$(scrub_list_file)" || return 0
  [ -n "$f" ] || return 0
  awk -v want="[$want]" '
    /^\[/        { insect = ($0 == want); next }
    !insect      { next }
    { sub(/#.*$/, ""); gsub(/[[:space:]]/, ""); if ($0 != "") print }
  ' "$f"
}

# scrub_env -- unset every [scrub] name. Records the ones that were actually
# SET into $SCRUBBED (names only, never values) so --explain can report what it
# took away. A scrub nobody can see is indistinguishable from one that did not
# run, which is the failure mode this whole file exists to end.
SCRUBBED=""
scrub_env() {
  local n
  while IFS= read -r n; do
    [ -n "$n" ] || continue
    if [ -n "${!n:-}" ]; then
      SCRUBBED="${SCRUBBED:+$SCRUBBED }$n"
    fi
    unset "$n" 2>/dev/null || true
  done < <(scrub_names scrub)
  export SCRUBBED
}
