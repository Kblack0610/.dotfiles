---
name: ci-analyze
description: Comprehensive CI analysis with parity checking, E2E tests, and full validation
allowed-tools: Bash, Read, Glob, Grep, AskUserQuestion
---

# Comprehensive CI Analysis

Full CI pipeline analysis with local parity verification. **STOPS if local setup doesn't match CI.**

## Workflow

### 1. Detect CI System

```bash
CI_SYSTEM="none"
[ -d ".github/workflows" ] && CI_SYSTEM="github-actions"
[ -f ".gitlab-ci.yml" ] && CI_SYSTEM="gitlab"
[ -f "Jenkinsfile" ] && CI_SYSTEM="jenkins"
[ -f ".circleci/config.yml" ] && CI_SYSTEM="circleci"
[ -f "bitbucket-pipelines.yml" ] && CI_SYSTEM="bitbucket"
[ -f ".travis.yml" ] && CI_SYSTEM="travis"
[ -f "azure-pipelines.yml" ] && CI_SYSTEM="azure"
echo "CI System: $CI_SYSTEM"
```

### 2. Analyze CI Pipeline

For GitHub Actions, read workflow files in `.github/workflows/`:
- Identify all jobs and steps
- Extract commands: test, lint, typecheck, build, e2e
- Note required environment variables and secrets
- Check for matrix builds, service containers

### 3. Analyze Local Setup

Check what's available locally:
- Package manager scripts (package.json scripts, Makefile, etc.)
- Test runners (jest, vitest, pytest, cargo test, go test)
- E2E frameworks (playwright, cypress, puppeteer)
- Required tools installed (check `which` or `command -v`)

### 4. Parity Check - STOP IF MISMATCH

**Compare CI vs Local and STOP if there are gaps:**

Report format:
```
## CI Pipeline Analysis

**CI System**: [detected system]

### CI Checks Found:
- [ ] typecheck: `pnpm typecheck`
- [ ] lint: `pnpm lint`
- [ ] unit tests: `pnpm test`
- [ ] e2e tests: `pnpm test:e2e`
- [ ] build: `pnpm build`

### Local Availability:
- [x] typecheck: Available (pnpm typecheck)
- [x] lint: Available (pnpm lint)
- [x] unit tests: Available (pnpm test)
- [ ] e2e tests: NOT AVAILABLE - missing playwright
- [x] build: Available (pnpm build)

### PARITY ISSUES FOUND:
1. **e2e tests**: CI runs `pnpm test:e2e` but playwright not installed locally
2. **env vars**: CI uses `DATABASE_URL` secret - ensure local .env is configured

**ACTION REQUIRED**: Fix parity issues before proceeding, or explicitly skip with --force
```

If parity issues exist, **STOP** and ask user:
- Fix the issues
- Skip specific checks with justification
- Proceed anyway with `--force` flag

### 5. Run Full CI Suite

Only after parity is confirmed (or --force):

```bash
# Basic checks
bash ~/.claude/hooks/pre-stop-checks.sh

# Unit tests
pnpm test 2>/dev/null || npm test 2>/dev/null || yarn test 2>/dev/null || cargo test 2>/dev/null || pytest 2>/dev/null || go test ./... 2>/dev/null

# E2E tests (if available and --with-e2e flag)
pnpm test:e2e 2>/dev/null || pnpm e2e 2>/dev/null || npx playwright test 2>/dev/null

# Build verification
pnpm build 2>/dev/null || npm run build 2>/dev/null || cargo build 2>/dev/null || go build ./... 2>/dev/null
```

## Flags

- `--force` - Proceed despite parity issues (use with caution)
- `--with-e2e` - Include E2E tests in the run
- `--skip-build` - Skip build verification
- `--skip-tests` - Only run linting/typecheck (same as /kb:ci)

## Environment Check

Also verify:
- Node version matches CI (check `.nvmrc`, `package.json engines`)
- Required env vars are set (check CI for secrets/env usage)
- Service dependencies available (databases, redis, etc.)

## Output

1. CI system and configuration summary
2. Parity comparison table
3. **STOP with action items if parity issues found**
4. Run results for each check category
5. Summary with pass/fail status
