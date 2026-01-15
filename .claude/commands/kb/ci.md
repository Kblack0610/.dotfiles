---
name: ci
description: Manually run all CI checks for the current project
allowed-tools: Bash
---

# Run CI Checks

Run the same checks that the Stop hook runs:

```bash
bash ~/.claude/hooks/pre-stop-checks.sh
```

## What It Checks

Based on project type:

**Node.js/TypeScript** (package.json):
- `pnpm typecheck` - Type checking
- `pnpm lint` - Linting
- `pnpm format:check` - Format verification
- `pnpm knip` - Dead code detection (if configured)

**Rust** (Cargo.toml):
- `cargo check` - Compilation check
- `cargo clippy` - Linting

**Python** (pyproject.toml/setup.py):
- `ruff check .` - Linting
- `mypy .` - Type checking

**Go** (go.mod):
- `go vet ./...` - Static analysis
- `golangci-lint run` - Linting

## Output

Report all results and any issues found. If checks fail, provide specific guidance on how to fix each issue.
