#!/bin/bash
# Stop check: Node/TypeScript projects (typecheck, lint, format, knip).
# Exit codes: 0=pass, 1=warn, 2=block.

set -uo pipefail

# Silence repeating .npmrc env-substitution warning when NPM_TOKEN is unset.
export NPM_TOKEN="${NPM_TOKEN:-}"

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
  pnpm turbo run typecheck lint $TURBO_FILTER --output-logs=errors-only 2>&1 || FAILED=1
  FMT_OUT=$(mktemp)
  pnpm format:check >"$FMT_OUT" 2>&1 || { FAILED=1; cat "$FMT_OUT" >&2; }
  rm -f "$FMT_OUT"
else
  echo "$PKG" | grep -q '"typecheck"' && { pnpm typecheck 2>&1 || FAILED=1; }
  echo "$PKG" | grep -q '"lint"' && { pnpm lint 2>&1 || FAILED=1; }
fi

KNIP_WARN=0
KNIP_OUT=$(mktemp)
echo "$PKG" | grep -q '"knip"' && {
  pnpm knip >"$KNIP_OUT" 2>&1 || {
    KNIP_WARN=1
    UNUSED=$(grep -cE '^(Unused|Unlisted)' "$KNIP_OUT" 2>/dev/null || echo 0)
    echo "knip: $UNUSED unused/unlisted entries (run \`pnpm knip\` for details)" >&2
  }
}
rm -f "$KNIP_OUT"

[ $FAILED -eq 1 ] && exit 2
[ $KNIP_WARN -eq 1 ] && exit 1
exit 0
