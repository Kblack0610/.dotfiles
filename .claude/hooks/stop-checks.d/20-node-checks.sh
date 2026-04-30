#!/bin/bash
# Stop check: Node/TypeScript projects (typecheck, lint, format, knip).
# Exit codes: 0=pass, 1=warn, 2=block.

set -uo pipefail

[ -f "package.json" ] || exit 0  # not applicable

PKG=$(cat package.json 2>/dev/null)
FAILED=0

if [ -f "turbo.json" ] || echo "$PKG" | grep -q '"turbo"'; then
  TURBO_FILTER=""
  if [ -d "apps" ] && git rev-parse --git-dir >/dev/null 2>&1; then
    BASE_BRANCH="origin/dev"
    git show-ref --verify --quiet refs/remotes/origin/dev || BASE_BRANCH="origin/main"
    CHANGED_APPS=$(git diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null | grep "^apps/" | cut -d'/' -f2 | sort -u)
    if [ -n "$CHANGED_APPS" ]; then
      for app in $CHANGED_APPS; do
        TURBO_FILTER="$TURBO_FILTER --filter=./apps/$app..."
      done
      echo "Scoping checks to changed apps: $CHANGED_APPS" >&2
    fi
  fi
  pnpm turbo run typecheck lint $TURBO_FILTER 2>&1 || FAILED=1
  pnpm format:check 2>&1 || FAILED=1
else
  echo "$PKG" | grep -q '"typecheck"' && { pnpm typecheck 2>&1 || FAILED=1; }
  echo "$PKG" | grep -q '"lint"' && { pnpm lint 2>&1 || FAILED=1; }
fi

KNIP_WARN=0
echo "$PKG" | grep -q '"knip"' && { pnpm knip 2>&1 || KNIP_WARN=1; }

[ $FAILED -eq 1 ] && exit 2
[ $KNIP_WARN -eq 1 ] && exit 1
exit 0
