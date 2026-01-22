#!/bin/bash
# Global CI check script - adapts to project type
# Runs before Claude finishes to enforce CI checks

cd "${CLAUDE_PROJECT_DIR:-.}"

echo "=== Running CI checks before completing ===" >&2

FAILED=0

# Detect project type and run appropriate checks
if [ -f "package.json" ]; then
  # Node.js / TypeScript project
  if [ -f "turbo.json" ] || grep -q '"turbo"' package.json 2>/dev/null; then
    # For monorepos, scope to changed apps to avoid pre-existing issues in unrelated packages
    TURBO_FILTER=""
    if [ -d "apps" ] && git rev-parse --git-dir > /dev/null 2>&1; then
      # Get the base branch (origin/dev or origin/main)
      BASE_BRANCH="origin/dev"
      git show-ref --verify --quiet refs/remotes/origin/dev || BASE_BRANCH="origin/main"
      # Find changed apps
      CHANGED_APPS=$(git diff --name-only "$BASE_BRANCH"...HEAD 2>/dev/null | grep "^apps/" | cut -d'/' -f2 | sort -u)
      if [ -n "$CHANGED_APPS" ]; then
        # Build filter for each changed app
        for app in $CHANGED_APPS; do
          TURBO_FILTER="$TURBO_FILTER --filter=./apps/$app..."
        done
        echo "Scoping checks to changed apps: $CHANGED_APPS" >&2
      fi
    fi
    echo "Running turbo checks..." >&2
    if [ -n "$TURBO_FILTER" ]; then
      pnpm turbo run typecheck lint $TURBO_FILTER 2>&1 || FAILED=1
      echo "Running format check..." >&2
      pnpm format:check 2>&1 || FAILED=1
    else
      pnpm turbo run typecheck lint 2>&1 || FAILED=1
      echo "Running format check..." >&2
      pnpm format:check 2>&1 || FAILED=1
    fi
  else
    [ -n "$(grep '"typecheck"' package.json 2>/dev/null)" ] && { echo "Running typecheck..." >&2; pnpm typecheck 2>&1 || FAILED=1; }
    [ -n "$(grep '"lint"' package.json 2>/dev/null)" ] && { echo "Running lint..." >&2; pnpm lint 2>&1 || FAILED=1; }
  fi
  # Knip is advisory - don't fail on warnings (pre-existing technical debt)
  [ -n "$(grep '"knip"' package.json 2>/dev/null)" ] && { echo "Running knip (advisory)..." >&2; pnpm knip 2>&1 || echo "Knip found issues (advisory only)" >&2; }

elif [ -f "Cargo.toml" ]; then
  # Rust project
  echo "Running cargo check..." >&2
  cargo check 2>&1 || FAILED=1
  echo "Running cargo clippy..." >&2
  cargo clippy 2>&1 || FAILED=1

elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  # Python project
  command -v ruff &>/dev/null && { echo "Running ruff..." >&2; ruff check . 2>&1 || FAILED=1; }
  command -v mypy &>/dev/null && { echo "Running mypy..." >&2; mypy . 2>&1 || FAILED=1; }

elif [ -f "go.mod" ]; then
  # Go project
  echo "Running go vet..." >&2
  go vet ./... 2>&1 || FAILED=1
  command -v golangci-lint &>/dev/null && { echo "Running golangci-lint..." >&2; golangci-lint run 2>&1 || FAILED=1; }

else
  echo "No recognized project type - skipping CI checks" >&2
  exit 0
fi

if [ $FAILED -eq 1 ]; then
  echo "" >&2
  echo "=== CI checks FAILED - Fix issues before completing ===" >&2
  exit 2  # Block Claude from stopping
fi

echo "=== All CI checks passed ===" >&2
exit 0
