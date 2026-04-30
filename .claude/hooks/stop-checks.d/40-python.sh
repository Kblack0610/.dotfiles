#!/bin/bash
# Stop check: Python projects (ruff + mypy).
# Exit codes: 0=pass, 2=block.

set -uo pipefail

if [ ! -f "pyproject.toml" ] && [ ! -f "setup.py" ]; then
  exit 0  # not applicable
fi

FAILED=0
command -v ruff >/dev/null 2>&1 && { ruff check . 2>&1 || FAILED=1; }
command -v mypy >/dev/null 2>&1 && { mypy . 2>&1 || FAILED=1; }

[ $FAILED -eq 1 ] && exit 2
exit 0
