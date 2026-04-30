#!/bin/bash
# Stop-pre check: Entire-Checkpoint session snapshot.
# Runs on every Stop including no-changes Q&A turns. Never blocks.
# Exit codes: 0=ok / not applicable, 1=warn (non-zero from entire).

set -uo pipefail

command -v entire >/dev/null 2>&1 || exit 0

if ! entire hooks claude-code stop; then
  echo "entire-snapshot: hook returned non-zero (advisory)" >&2
  exit 1
fi
exit 0
