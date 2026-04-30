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

UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null)
if [ -z "$UPSTREAM" ]; then
  AHEAD=$(git rev-list "$MAIN_BRANCH"..HEAD --count 2>/dev/null)
  if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
    echo "FAILED: Branch '$BRANCH' has $AHEAD unpushed commit(s) with no remote tracking branch" >&2
    FAILED=1
  fi
else
  AHEAD=$(git rev-list "$UPSTREAM"..HEAD --count 2>/dev/null)
  if [ "${AHEAD:-0}" -gt 0 ] 2>/dev/null; then
    echo "FAILED: Branch '$BRANCH' has $AHEAD unpushed commit(s)" >&2
    FAILED=1
  fi
fi

WARN=0
if command -v gh >/dev/null 2>&1; then
  PR_STATE=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)
  if [ "$PR_STATE" = "OPEN" ]; then
    PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null)
    echo "Open PR not yet merged (may be pre-existing): $PR_URL" >&2
    WARN=1
  fi
fi

[ $FAILED -eq 1 ] && exit 2
[ $WARN -eq 1 ] && exit 1
exit 0
