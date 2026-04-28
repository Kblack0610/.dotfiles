#!/bin/bash
# Global CI check script - adapts to project type
# Runs before Claude finishes to enforce CI checks

cd "${CLAUDE_PROJECT_DIR:-.}"

# Loop guard: Claude Code sets stop_hook_active=true on stdin after we block
# once this turn. Blocking again traps the agent. Exit clean on the second call.
PAYLOAD=$(cat 2>/dev/null || echo '{}')
if command -v jq >/dev/null 2>&1 && [ "$(echo "$PAYLOAD" | jq -r '.stop_hook_active // false' 2>/dev/null)" = "true" ]; then
  echo "pre-stop-checks: loop guard — already blocked once this turn, exiting clean" >&2
  exit 0
fi

FAILED=0

# --- CI result file (read by rules-compliance-check.sh for eval scoring) ---
_PROJ=$(basename "${CLAUDE_PROJECT_DIR:-$PWD}")
_DATE=$(date +%Y-%m-%d)
CI_RESULT_FILE="${XDG_CACHE_HOME:-$HOME/.cache}/claude-stop-hook/ci-result-${_PROJ}-${_DATE}.txt"
CI_STATUS="UNKNOWN"
CI_NOTE=""
E2E_COVERAGE="PASS"
E2E_NOTE=""

write_ci_result() {
  mkdir -p "$(dirname "$CI_RESULT_FILE")" 2>/dev/null || true
  {
    echo "status=$CI_STATUS"
    echo "note=$CI_NOTE"
    echo "ts=$(date +%s)"
    echo "e2e_coverage=$E2E_COVERAGE"
    echo "e2e_note=$E2E_NOTE"
  } > "$CI_RESULT_FILE" 2>/dev/null || true
}
trap write_ci_result EXIT

# --- E2E + UI walkthrough verification gate (PlaceMyParents) ---
# Codified rule:
# ~/.claude/projects/-home-kblack0610-dev-bnb-platform/memory/feedback_e2e_and_manual_verification.md
# Triggers only when the diff touches placemyparents user-facing screens.
check_e2e_coverage() {
  if ! git rev-parse --git-dir > /dev/null 2>&1; then return 0; fi

  local cur_branch base_branch base_ref diff_files screens specs skips walkthroughs
  cur_branch=$(git branch --show-current 2>/dev/null)
  base_branch="develop"
  git show-ref --verify --quiet refs/remotes/origin/develop || base_branch="main"
  base_ref="origin/${base_branch}"
  git show-ref --verify --quiet "refs/remotes/${base_ref}" || base_ref="${base_branch}"

  # Compare against the merge-base so the gate sees committed work on the branch,
  # not just uncommitted-vs-HEAD. Falls back gracefully if the merge-base lookup fails.
  local mb
  mb=$(git merge-base "$base_ref" HEAD 2>/dev/null || echo "$base_ref")
  diff_files=$(git diff --name-only "${mb}..HEAD" 2>/dev/null; git diff --name-only HEAD 2>/dev/null; git diff --cached --name-only 2>/dev/null)
  diff_files=$(echo "$diff_files" | sort -u | grep -v '^$')

  # Bail out cleanly if no diff at all (covered by other early-exits, but defensive).
  [ -z "$diff_files" ] && return 0

  screens=$(echo "$diff_files" | grep -E '^apps/placemyparents/(web/src/app/.*\.tsx$|mobile/src/(screens|components)/.*\.tsx$)' | grep -v '__tests__' || true)
  [ -z "$screens" ] && return 0  # No screen changes → gate is N/A → PASS

  specs=$(echo "$diff_files" | grep -E '^apps/placemyparents/(web/tests/e2e/.*\.spec\.ts$|mobile/maestro/.*\.ya?ml$)' || true)
  walkthroughs=$(echo "$diff_files" | grep -E '^docs/runbooks/ui-walkthroughs/' || true)

  # Skip markers inside the changed screens — defensive grep against the diff text itself
  skips=0
  while IFS= read -r f; do
    [ -z "$f" ] && continue
    if git diff "${mb}..HEAD" -- "$f" 2>/dev/null | grep -qE 'SKIP: e2e-not-applicable'; then
      skips=$((skips + 1))
    fi
  done <<< "$screens"

  local screen_count
  screen_count=$(echo "$screens" | grep -cE '.+' || echo 0)

  if [ -n "$specs" ] || [ -n "$walkthroughs" ]; then
    E2E_COVERAGE="PASS"
    E2E_NOTE="screens=$screen_count, specs=$(echo "$specs" | grep -cE '.+' || echo 0), walkthroughs=$(echo "$walkthroughs" | grep -cE '.+' || echo 0)"
  elif [ "$skips" -eq "$screen_count" ] && [ "$screen_count" -gt 0 ]; then
    E2E_COVERAGE="PASS"
    E2E_NOTE="$screen_count screen change(s), all marked SKIP: e2e-not-applicable"
  elif [ "$skips" -gt 0 ]; then
    E2E_COVERAGE="WARN"
    E2E_NOTE="$screen_count screen change(s), $skips with skip-marker, no e2e/walkthrough for the rest"
  else
    E2E_COVERAGE="FAIL"
    E2E_NOTE="$screen_count screen change(s) without e2e spec, walkthrough evidence, or SKIP: e2e-not-applicable marker — see feedback_e2e_and_manual_verification.md"
  fi
}

check_e2e_coverage 2>/dev/null || true

# --- Git workflow completeness checks ---
if git rev-parse --git-dir > /dev/null 2>&1; then
  BRANCH=$(git branch --show-current 2>/dev/null)
  MAIN_BRANCH="develop"
  git show-ref --verify --quiet refs/remotes/origin/develop || MAIN_BRANCH="main"

  if [ -n "$BRANCH" ] && [ "$BRANCH" != "$MAIN_BRANCH" ] && [ "$BRANCH" != "main" ] && [ "$BRANCH" != "master" ]; then
    UPSTREAM=$(git rev-parse --abbrev-ref "@{upstream}" 2>/dev/null)
    if [ -z "$UPSTREAM" ]; then
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

    if command -v gh &>/dev/null; then
      PR_STATE=$(gh pr view "$BRANCH" --json state --jq '.state' 2>/dev/null)
      if [ "$PR_STATE" = "OPEN" ]; then
        PR_URL=$(gh pr view "$BRANCH" --json url --jq '.url' 2>/dev/null)
        echo "WARNING: Open PR not yet merged (may be pre-existing): $PR_URL" >&2
      fi
    fi
  fi
fi

# Skip CI if no uncommitted changes (nothing to lint/typecheck)
if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
  if [ $FAILED -eq 1 ]; then
    echo "=== Workflow checks FAILED - Complete the PR/merge workflow before finishing ===" >&2
    CI_STATUS="FAIL"
    CI_NOTE="git workflow: unpushed commits or uncommitted state"
    exit 2
  fi
  CI_STATUS="SKIPPED"
  CI_NOTE="no local changes"
  exit 0
fi

echo "=== Running CI checks before completing ===" >&2

# We're here because there ARE changes — warn unconditionally.
if git rev-parse --git-dir > /dev/null 2>&1; then
  echo "WARNING: Uncommitted changes in worktree (may be pre-existing)" >&2
  UNTRACKED=$(git ls-files --others --exclude-standard 2>/dev/null | head -5)
  if [ -n "$UNTRACKED" ]; then
    echo "WARNING: Untracked files found (may need to be committed):" >&2
    echo "$UNTRACKED" >&2
  fi
fi

# Detect project type and run appropriate checks
if [ -f "package.json" ]; then
  PKG=$(cat package.json 2>/dev/null)
  if [ -f "turbo.json" ] || echo "$PKG" | grep -q '"turbo"'; then
    TURBO_FILTER=""
    if [ -d "apps" ] && git rev-parse --git-dir > /dev/null 2>&1; then
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
  # Knip is advisory — don't fail on warnings (pre-existing technical debt)
  echo "$PKG" | grep -q '"knip"' && { pnpm knip 2>&1 || echo "Knip found issues (advisory only)" >&2; }

elif [ -f "Cargo.toml" ]; then
  cargo check 2>&1 || FAILED=1
  cargo clippy 2>&1 || FAILED=1

elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
  command -v ruff &>/dev/null && { ruff check . 2>&1 || FAILED=1; }
  command -v mypy &>/dev/null && { mypy . 2>&1 || FAILED=1; }

elif [ -f "go.mod" ]; then
  go vet ./... 2>&1 || FAILED=1
  command -v golangci-lint &>/dev/null && { golangci-lint run 2>&1 || FAILED=1; }

else
  CI_STATUS="SKIPPED"
  CI_NOTE="no recognized project type (no package.json/Cargo.toml/pyproject.toml/go.mod)"
  exit 0
fi

if [ $FAILED -eq 1 ]; then
  echo "=== CI checks FAILED - Fix issues before completing ===" >&2
  CI_STATUS="FAIL"
  CI_NOTE="typecheck/lint/format failed (see stderr above)"
  exit 2
fi

CI_STATUS="PASS"
CI_NOTE="all checks passed"
echo "=== All CI checks passed ===" >&2
exit 0
