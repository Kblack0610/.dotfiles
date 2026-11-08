#!/bin/bash
# Stop check: Go projects (go vet + golangci-lint).
# Exit codes: 0=pass, 2=block.

set -uo pipefail

[ -f "go.mod" ] || exit 0  # not applicable

go vet ./... 2>&1 || exit 2
command -v golangci-lint >/dev/null 2>&1 && { golangci-lint run 2>&1 || exit 2; }

exit 0
