#!/bin/bash
# Stop check: Rust/Cargo projects (cargo check + clippy).
# Exit codes: 0=pass, 2=block.

set -uo pipefail

[ -f "Cargo.toml" ] || exit 0  # not applicable

FAILED=0
cargo check 2>&1 || FAILED=1
cargo clippy 2>&1 || FAILED=1

[ $FAILED -eq 1 ] && exit 2
exit 0
