#!/bin/bash
# Global CI check script - adapts to project type
# Runs before Claude finishes to enforce CI checks

cd "${CLAUDE_PROJECT_DIR:-.}"

FAILED=0

# --- CI result file (read by rules-compliance-check.sh for eval scoring) ---
_PROJ=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
_DATE=$(date +%Y-%m-%d)
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${_PROJ}-${_DATE}.txt"
CI_STATUS="UNKNOWN"
CI_NOTE=""

write_ci_result() {
  mkdir -p "$(dirname "$CI_RESULT_FILE")" 2>/dev/null || true
  { echo "status=$CI_STATUS"; echo "note=$CI_NOTE"; echo "ts=$(date +%s)"; } > "$CI_RESULT_FILE" 2>/dev/null || true
}
trap write_ci_result EXIT

# --- Git workflow completeness checks ---
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  MAIN_BRANCH="develop"
  git show-ref --verify --quiet refs/remotes/origin/develop || MAIN_BRANCH="main"

  # Check for uncommitted changes (staged or unstaged)
  # Only warn — dirty worktrees may be pre-existing from other agents/branches
  if ! git diff --quiet HEAD 2>/dev/null || ! git diff --cached --quiet 2>/dev/null; then
    echo "WARNING: Uncommitted changes in worktree (may be pre-existing)" >&2
  fi

  # Check for untracked files in tracked directories (new files not yet added)
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | head -5)
  if [ -n "$UNTRACKED" ]; then
    echo "WARNING: Untracked files found (may need to be committed):" >&2
    echo "$UNTRACKED" >&2
  fi

  # Check for unpushed commits on non-main branches
  if [ -n "$BRANCH" ] && [ "$BRANCH" != "$MAIN_BRANCH" ] && [ "$BRANCH" != "main" ] && [ "$BRANCH" != "master" ]; then
    UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null)
    if [ -z "$UPSTREAM" ]; then
      # Branch has no upstream - check if it has commits ahead of main
      AHEAD=$(git rev-list "$MAIN_BRANCH"..HEAD --count 2>/dev/null)
      if [ "$AHEAD" -gt 0 ] 2>/dev/null; then
        echo "FAILED: Branch '$BRANCH' has $AHEAD unpushed commit(s) with no remote tracking branch" >&2
        FAILED=1
      fi
    else
      AHEAD=$(git rev-list "$UPSTREAM"..HEAD --count 2>/dev/null)
      if [ "$AHEAD" -gt 0 ] 2>/dev/null; then
        echo "FAILED: Branch '$BRANCH' has $AHEAD unpushed commit(s)" >&2
        FAILED=1
      fi
    fi

    # Check for open unmerged PR on current branch
    if command -v gh &>/dev/null; then
      PR_STATE=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)
      if [ "$PR_STATE" = "OPEN" ]; then
        PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null)
        echo "WARNING: Open PR not yet merged (may be pre-existing): $PR_URL" >&2
      fi
    fi
  fi
fi

# Skip CI checks if no uncommitted changes (nothing to lint/typecheck)
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  if [ $FAILED -eq 1 ]; then
    echo "" >&2
    echo "=== Workflow checks FAILED - Complete the PR/merge workflow before finishing ===" >&2
    CI_STATUS="FAIL"
    CI_NOTE="git workflow: unpushed commits or uncommitted state"
    exit 2
  fi
  CI_STATUS="SKIPPED"
  CI_NOTE="no local changes"
  echo "No local changes - skipping CI checks" >&2
  exit 0
fi

echo "=== Running CI checks before completing ===" >&2

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
  CI_STATUS="SKIPPED"
  CI_NOTE="no recognized project type (no package.json/Cargo.toml/pyproject.toml/go.mod)"
  echo "No recognized project type - skipping CI checks" >&2
  exit 0
fi

if [ $FAILED -eq 1 ]; then
  echo "" >&2
  echo "=== CI checks FAILED - Fix issues before completing ===" >&2
  CI_STATUS="FAIL"
  CI_NOTE="typecheck/lint/format failed (see stderr above)"
  exit 2  # Block Claude from stopping
fi

CI_STATUS="PASS"
CI_NOTE="all checks passed"
echo "=== All CI checks passed ===" >&2
exit 0
