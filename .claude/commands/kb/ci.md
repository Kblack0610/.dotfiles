---
name: ci
description: Quick CI checks - runs linting, typecheck, format validation
allowed-tools: Bash
---

# Quick CI Checks

Run fast local CI validation (linting, types, formatting).

```bash
bash ~/.claude/hooks/pre-stop-checks.sh
```

## What Runs

**Node.js/TypeScript**: typecheck, lint, format:check, knip
**Rust**: cargo check, clippy
**Python**: ruff, mypy
**Go**: go vet, golangci-lint

For comprehensive CI analysis with parity checking and E2E tests, use `/kb:ci-analyze`.
