#!/bin/bash
# Stop check: git workflow completeness.
# Exit codes: 0=pass, 1=warn, 2=block.

set -uo pipefail

git rev-parse --git-dir >/dev/null 2>&1 || exit 0  # not a git repo

BRANCH=$(git branch --show-current 2>/dev/null)
[ -z "$BRANCH" ] && exit 0
[ "$BRANCH" = "main" ] || [ "$BRANCH" = "master" ] && exit 0

MAIN_BRANCH="develop"
git show-ref --verify --quiet refs/remotes/origin/develop || MAIN_BRANCH="main"
[ "$BRANCH" = "$MAIN_BRANCH" ] && exit 0

FAILED=0
WARN=0

# A turn that ends while this session's own background run (its gate, a test run) is still
# going is not the end of the work: the run's notice wakes the session and that Stop checks
# again. Claude Code points a background run's stdout at
# <tmp>/claude-<uid>/<cwd>/<session>/tasks/<id>.output, so a live run is a process holding
# that file open. 2026-10-29..11-05: 205 of the 207 unpushed-commit blocks came mid-run.
inflight() {
  [ -n "${STOP_SESSION_ID:-}" ] || return 1
  [ -n "$(find /proc/[0-9]*/fd -lname "*/${STOP_SESSION_ID}/tasks/*.output" -print -quit 2>/dev/null)" ]
}

unpushed() {
  if inflight; then
    echo "$1; a background run of this session is still going, so the next Stop checks again" >&2
    WARN=1
  else
    echo "FAILED: $1" >&2
    FAILED=1
  fi
}

UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null)
if [ -z "$UPSTREAM" ]; then
  AHEAD=$(git rev-list "$MAIN_BRANCH"..HEAD --count 2>/dev/null)
  if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
    unpushed "Branch '$BRANCH' has $AHEAD unpushed commit(s) with no remote tracking branch"
  fi
else
  AHEAD=$(git rev-list "$UPSTREAM"..HEAD --count 2>/dev/null)
  if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
    unpushed "Branch '$BRANCH' has $AHEAD unpushed commit(s)"
  fi
fi

if command -v gh >/dev/null 2>&1; then
  # Bounded: offline, gh waits on the network and this runs on every Stop.
  PR=$(timeout 5 gh pr view "$BRANCH" --json state,url --jq '.state + " " + .url' 2>/dev/null)
  if [ "${PR%% *}" = "OPEN" ]; then
    echo "Open PR not yet merged (may be pre-existing): ${PR#* }" >&2
    WARN=1
  fi
fi

[ $FAILED -eq 1 ] && exit 2
[ $WARN -eq 1 ] && exit 1
exit 0
