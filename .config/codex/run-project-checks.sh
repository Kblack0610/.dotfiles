#!/bin/bash
set -euo pipefail

cd "${1:-.}"

if git rev-parse --git-dir >/dev/null 2>&1; then
    if git diff --quiet HEAD 2>/dev/null && git diff --cached --quiet 2>/dev/null; then
        echo "No changes detected - skipping project checks" >&2
        exit 0
    fi
fi

failed=0

if [ -f "package.json" ]; then
    if [ -f "turbo.json" ] || grep -q '"turbo"' package.json 2>/dev/null; then
        turbo_filter=""
        if [ -d "apps" ] && git rev-parse --git-dir >/dev/null 2>&1; then
            base_branch="origin/dev"
            git show-ref --verify --quiet refs/remotes/origin/dev || base_branch="origin/main"
            changed_apps=$(git diff --name-only "$base_branch"...HEAD 2>/dev/null | grep "^apps/" | cut -d'/' -f2 | sort -u || true)
            if [ -n "$changed_apps" ]; then
                for app in $changed_apps; do
                    turbo_filter="$turbo_filter --filter=./apps/$app..."
                done
                echo "Scoping checks to changed apps: $changed_apps" >&2
            fi
        fi
        echo "Running turbo checks..." >&2
        if [ -n "$turbo_filter" ]; then
            pnpm turbo run typecheck lint $turbo_filter 2>&1 || failed=1
            pnpm format:check 2>&1 || failed=1
        else
            pnpm turbo run typecheck lint 2>&1 || failed=1
            pnpm format:check 2>&1 || failed=1
        fi
    else
        grep -q '"typecheck"' package.json 2>/dev/null && { echo "Running typecheck..." >&2; pnpm typecheck 2>&1 || failed=1; }
        grep -q '"lint"' package.json 2>/dev/null && { echo "Running lint..." >&2; pnpm lint 2>&1 || failed=1; }
    fi
    grep -q '"knip"' package.json 2>/dev/null && { echo "Running knip (advisory)..." >&2; pnpm knip 2>&1 || echo "Knip found issues (advisory only)" >&2; }
elif [ -f "Cargo.toml" ]; then
    echo "Running cargo check..." >&2
    cargo check 2>&1 || failed=1
    echo "Running cargo clippy..." >&2
    cargo clippy 2>&1 || failed=1
elif [ -f "pyproject.toml" ] || [ -f "setup.py" ]; then
    command -v ruff >/dev/null 2>&1 && { echo "Running ruff..." >&2; ruff check . 2>&1 || failed=1; }
    command -v mypy >/dev/null 2>&1 && { echo "Running mypy..." >&2; mypy . 2>&1 || failed=1; }
elif [ -f "go.mod" ]; then
    echo "Running go vet..." >&2
    go vet ./... 2>&1 || failed=1
    command -v golangci-lint >/dev/null 2>&1 && { echo "Running golangci-lint..." >&2; golangci-lint run 2>&1 || failed=1; }
else
    echo "No recognized project type - skipping project checks" >&2
    exit 0
fi

if [ "$failed" -eq 1 ]; then
    echo "Project checks failed" >&2
    exit 2
fi

echo "Project checks passed" >&2
