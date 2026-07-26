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

if command -v shellcheck >/dev/null 2>&1; then
  if shellcheck --severity="$SEVERITY" -x "${FILES[@]}"; then
    echo "shellcheck: clean at severity=$SEVERITY (${#FILES[@]} files)"
  else
    echo "shellcheck: FAILED at severity=$SEVERITY" >&2
    rc=1
  fi
else
  echo "shellcheck: NOT INSTALLED (skipped)"
fi

if command -v shfmt >/dev/null 2>&1; then
  if shfmt -d -i 2 -ci "${FILES[@]}" > /tmp/shfmt.diff 2>&1 && [ ! -s /tmp/shfmt.diff ]; then
    echo "shfmt: clean"
  elif [ "$SHFMT_GATE" = 1 ]; then
    cat /tmp/shfmt.diff >&2
    echo "shfmt: FAILED (SHFMT_GATE=1)" >&2
    rc=1
  else
    echo "shfmt: $(grep -c '^--- ' /tmp/shfmt.diff 2>/dev/null || echo '?') files would change (advisory; SHFMT_GATE=1 to enforce)"
  fi
else
  echo "shfmt: NOT INSTALLED (skipped)"
fi

exit $rc
