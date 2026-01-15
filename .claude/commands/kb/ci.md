---
name: ci
description: Manually run all CI checks for the current project
allowed-tools: Bash, Read, Glob, Grep
---

# Run CI Checks

Run local CI validation matching your project's CI pipeline.

## Workflow

### 1. Detect CI Configuration

First, identify the CI system in use:

```bash
# Check for CI configuration files
CI_SYSTEM="unknown"
[ -d ".github/workflows" ] && CI_SYSTEM="github-actions"
[ -f ".gitlab-ci.yml" ] && CI_SYSTEM="gitlab"
[ -f "Jenkinsfile" ] && CI_SYSTEM="jenkins"
[ -f ".circleci/config.yml" ] && CI_SYSTEM="circleci"
[ -f "bitbucket-pipelines.yml" ] && CI_SYSTEM="bitbucket"
[ -f ".travis.yml" ] && CI_SYSTEM="travis"
[ -f "azure-pipelines.yml" ] && CI_SYSTEM="azure"
echo "Detected CI: $CI_SYSTEM"
```

### 2. Analyze CI Pipeline

If GitHub Actions detected, read the main workflow files to understand what checks run:
- Look at `.github/workflows/*.yml` for `test`, `lint`, `check`, `build` workflows
- Identify the actual commands being run

### 3. Confirm Parity

**IMPORTANT**: Before running checks, confirm with the user:

> "I've detected [CI_SYSTEM] with the following checks configured:
> - [list detected checks]
>
> The local pre-stop-checks script will run:
> - [list local checks]
>
> **Parity Check**: [Confirm if local checks match CI, or note any gaps]
>
> Do you want me to proceed with running the local checks?"

Note any discrepancies such as:
- Tests that only run in CI (e.g., E2E tests requiring infrastructure)
- Different tool versions between local and CI
- Missing local equivalents for CI steps

### 4. Run Checks

Execute the project-type-appropriate checks:

```bash
bash ~/.claude/hooks/pre-stop-checks.sh
```

## Project Type Detection

Based on project files, runs appropriate checks:

**Node.js/TypeScript** (package.json):
- `pnpm typecheck` - Type checking
- `pnpm lint` - Linting
- `pnpm format:check` - Format verification
- `pnpm knip` - Dead code detection (if configured)
- `pnpm test` - Unit tests (if configured)

**Rust** (Cargo.toml):
- `cargo check` - Compilation check
- `cargo clippy` - Linting
- `cargo test` - Tests

**Python** (pyproject.toml/setup.py):
- `ruff check .` - Linting
- `mypy .` - Type checking
- `pytest` - Tests

**Go** (go.mod):
- `go vet ./...` - Static analysis
- `golangci-lint run` - Linting
- `go test ./...` - Tests

## Output

1. Report detected CI system and configuration
2. List parity status between local and CI checks
3. Run all applicable checks
4. Report results with specific guidance for any failures

## Flags

- `--skip-parity` - Skip the parity confirmation prompt
- `--include-tests` - Also run test suite (not just linting/type checks)
- `--verbose` - Show detailed output from each check
