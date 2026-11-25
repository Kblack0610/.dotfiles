#!/usr/bin/env bash
# Vendor bats-core and its two helpers into tests/vendor, pinned so a CI run and a laptop run
# agree. A shell script, not a make rule, because the CI runner pod image has no make
# (hc-1019, 2026-11-24): tests/docker.sh and .github/actions/bats-vendor call this directly,
# and `make -C tests bootstrap` calls it too. The refs below are the only copy; the
# bats-vendor cache key hashes these three lines.
set -euo pipefail

BATS_REF=v1.12.0
SUPPORT_REF=v0.3.0
ASSERT_REF=v2.1.0

VENDOR="$(cd "$(dirname "$0")" && pwd)/vendor"
BATS="$VENDOR/bats-core/bin/bats"

# All three, not just bats: a failed helper clone must be retried, not skipped as "vendored".
[ -x "$BATS" ] && [ -d "$VENDOR/bats-support" ] && [ -d "$VENDOR/bats-assert" ] && exit 0

mkdir -p "$VENDOR"
echo "==> vendoring bats-core $BATS_REF + helpers into tests/vendor"
[ -d "$VENDOR/bats-core" ] || git clone --quiet --depth 1 --branch "$BATS_REF" https://github.com/bats-core/bats-core.git "$VENDOR/bats-core"
[ -d "$VENDOR/bats-support" ] || git clone --quiet --depth 1 --branch "$SUPPORT_REF" https://github.com/bats-core/bats-support.git "$VENDOR/bats-support"
[ -d "$VENDOR/bats-assert" ] || git clone --quiet --depth 1 --branch "$ASSERT_REF" https://github.com/bats-core/bats-assert.git "$VENDOR/bats-assert"
echo "==> ok: $("$BATS" --version)"
