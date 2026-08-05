#!/usr/bin/env bash
# The lint gate. Single entry point for `make -C tests lint`, the Stop hook, and CI, so all
# three enforce exactly the same thing -- a gate that differs between local and CI gets
# ignored the first time it disagrees.
#
# THE RATCHET
# -----------
# SEVERITY starts at the strictest level that is green across the whole tree, and moves one
# notch down as findings get fixed:  error -> warning -> info -> style.  That is a one-line
# diff per step, with no baseline file to maintain and no stale suppressions to rot.
#
# Do NOT jump straight to `style`. This repo has ~134 shell scripts written before any
# linting existed, so a big-bang change produces a permanently red check that everyone
# learns to ignore.
#
# Current state, measured 2026-07-26 over 134 files (shellcheck 0.11.0):
#   error    0     <- the gate
#   warning  328
#   info     79
#   style    4
# Re-measure before each notch down:
#   docker run --rm -v "$PWD:/work" -w /work <img> shellcheck -x $(tests/lint-files.sh)
#
# This flag CANNOT live in .shellcheckrc: `severity=` is not a supported directive there and
# is silently ignored. See the comment at the top of .shellcheckrc.
SEVERITY="${SHELLCHECK_SEVERITY:-error}"

# shfmt is advisory for now, for the same reason: the tree was never formatted, so gating on
# it today would be a big-bang red. Set SHFMT_GATE=1 to make it blocking once it is clean.
SHFMT_GATE="${SHFMT_GATE:-0}"

# No `-e`: this script reports on several tools and accumulates rc, so an individual failure
# must not abort it. That makes the explicit `|| exit` on cd load-bearing (SC2164).
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

mapfile -t FILES < <(tests/lint-files.sh)
# An empty list is a BROKEN GATE, not a clean tree - this repo has ~140 shell scripts, so
# zero can only mean lint-files.sh could not enumerate them. Exiting 0 here would report
# "clean" having checked nothing.
[ "${#FILES[@]}" -gt 0 ] || {
  echo "lint: refusing to pass - the file list came back EMPTY (see lint-files.sh)" >&2
  exit 1
}

rc=0
ran=() skipped=()

# ── house rules ──────────────────────────────────────────────────────────────
# Two repo-specific rules shellcheck cannot express. Deliberately implemented in
# pure shell with no external tool, because the two gates below BOTH skip when
# their binary is missing -- which is the whole state this section exists to stop
# being invisible. On a host without shellcheck and shfmt, everything above this
# printed "NOT INSTALLED (skipped)" and the gate still exited 0.

# RULE 1: a test may not re-parse a subject out of its source file.
#
#   eval "$(sed -n '/^fn()/,/^}/p' some-script.sh)"
#
# This transplants a function WITHOUT its program: no sourced libraries, no
# module-level variables, none of its sibling helpers. wave_session.bats extracted
# five functions this way and they lost both AGENT_PLANS_DIR and the awk source
# string _BOARD_STAGE_AWK -- so the tests exercised a shape the shipped program
# never runs in. It also makes the file's TEXT LAYOUT a test dependency: the range
# ends at the first column-0 `}`, so an embedded awk program silently truncates the
# extraction mid-function.
#
# The fix is always the same and always cheaper: give the script a
# `[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0` guard and source it.
if hits=$(grep -rn 'eval .*\$(sed -n' tests/ --include='*.bats' --include='*.bash' 2>/dev/null); then
  echo "house-rules: FAILED - a test re-parses a subject out of its source file:" >&2
  printf '%s\n' "$hits" | sed 's/^/  /' >&2
  echo "  Add a source guard to the subject and source it instead. See tests/lint.sh." >&2
  rc=1
else
  echo "house-rules: no sed-extracted subjects"
fi

# RULE 2: every tmux script carries the source guard, so rule 1 always has an out.
# A script without one cannot be sourced by a test at all -- running it executes its
# verb dispatch, which for most of these means `usage; exit 2`. That is why the
# extraction pattern got invented in the first place.
missing=()
for f in .local/src/tmux/*.sh; do
  [ -f "$f" ] || continue
  grep -q 'BASH_SOURCE\[0\]' "$f" || missing+=("$f")
done
# Same empty-list reasoning as FILES above: zero files checked means the glob broke,
# not that the tree is clean.
if [ ! -f .local/src/tmux/notes-cockpit.sh ]; then
  echo "house-rules: refusing to pass - .local/src/tmux/ did not enumerate" >&2
  rc=1
elif [ "${#missing[@]}" -gt 0 ]; then
  echo "house-rules: FAILED - tmux script with no source guard (tests cannot source it):" >&2
  printf '  %s\n' "${missing[@]}" >&2
  echo '  Add: [[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0   (before the verb dispatch)' >&2
  rc=1
else
  echo "house-rules: every tmux script has a source guard"
fi
ran+=("house-rules")

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity="$SEVERITY" -x "${FILES[@]}"; then
    echo "shellcheck: clean at severity=$SEVERITY (${#FILES[@]} files)"
    ran+=("shellcheck")
  else
    echo "shellcheck: FAILED at severity=$SEVERITY" >&2
    ran+=("shellcheck")
    rc=1
  fi
else
  echo "shellcheck: NOT INSTALLED (skipped)"
  skipped+=("shellcheck")
fi

if command -v shfmt >/dev/null 2>&1; then
  if shfmt -d -i 2 -ci "${FILES[@]}" > /tmp/shfmt.diff 2>&1 && [ ! -s /tmp/shfmt.diff ]; then
    echo "shfmt: clean"
    ran+=("shfmt")
  elif [ "$SHFMT_GATE" = 1 ]; then
    cat /tmp/shfmt.diff >&2
    echo "shfmt: FAILED (SHFMT_GATE=1)" >&2
    rc=1
  else
    echo "shfmt: $(grep -c '^--- ' /tmp/shfmt.diff 2>/dev/null || echo '?') files would change (advisory; SHFMT_GATE=1 to enforce)"
    ran+=("shfmt")
  fi
else
  echo "shfmt: NOT INSTALLED (skipped)"
  skipped+=("shfmt")
fi

# Say what actually RAN. Without this the difference between "three gates passed" and
# "two gates were not installed and the third said nothing" is a line of prose in the
# middle of the output that nobody reads -- and both exit 0. A skipped gate is not a
# passing gate, and the summary is where that stops being deniable.
printf 'lint: ran %s' "$(IFS=,; echo "${ran[*]:-none}")"
[ "${#skipped[@]}" -gt 0 ] && printf '; SKIPPED (not installed): %s' "$(IFS=,; echo "${skipped[*]}")"
printf '\n'

exit $rc
