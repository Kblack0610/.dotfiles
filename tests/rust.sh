#!/usr/bin/env bash
# The Rust gate. Single entry point for `make -C tests test-rust` and the CI rust job,
# for the same reason lint.sh is shared: a gate that differs between local and CI gets
# ignored the first time it disagrees.
#
# WHY THIS EXISTS
# ---------------
# Three crates ship from this repo -- notes-cli, agent-panel, timebox -- carrying 188
# in-tree tests between them, and until this file NONE of them ran anywhere. The CI
# workflow had four jobs and zero cargo. The failure was silent in both directions:
# nothing ran the tests, and build_local_rust_tools() in the installer treats a build
# failure as non-fatal on purpose (so a broken install still proceeds), leaving the
# PREVIOUS binary on PATH. So a crate could stop compiling and the only symptom would be
# a tool that quietly kept behaving like an older version.
#
# THE RATCHET
# -----------
# Same shape as lint.sh's SEVERITY ladder: each gate starts advisory if it is not green
# across the whole tree today, and flips to blocking in a one-line diff once it is. No
# baseline file, no per-crate suppressions to rot.
#
# Current state, measured 2026-08-09 (rustc/clippy 0.1.93, rustfmt 1.8.0):
#   cargo test     188 passing, 0 failing   <- BLOCKING from day one
#   cargo clippy   7 warnings, 0 errors     <- advisory (CLIPPY_GATE=1 to enforce)
#   cargo fmt      3 of 3 crates unformatted <- advisory (RUSTFMT_GATE=1 to enforce)
#
# Do not flip the two advisory gates in the same PR that fixes their findings: a
# `cargo fmt` over notes-cli alone rewrites 22 files, and burying the gate change in that
# diff is how a formatting sweep gets reviewed as a no-op.
CLIPPY_GATE="${CLIPPY_GATE:-0}"
RUSTFMT_GATE="${RUSTFMT_GATE:-0}"

# No `-e`: this script runs several gates over several crates and accumulates rc, so one
# failure must not abort the rest. That makes the explicit `|| exit` on cd load-bearing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

if ! command -v cargo >/dev/null 2>&1; then
  # Deliberately rc=0. Same contract as lint.sh's "NOT INSTALLED (skipped)": a machine
  # without a Rust toolchain is a supported state for a dotfiles repo, and the Stop hook
  # must not turn into a red gate on one. CI installs the toolchain, so CI still runs it.
  echo "rust: cargo NOT INSTALLED (skipped)"
  exit 0
fi

mapfile -t CRATES < <(tests/rust-crates.sh)

# An empty list is a BROKEN GATE, not a clean tree -- the exact bug this whole file was
# written to close. Three crates are tracked; zero can only mean rust-crates.sh could not
# enumerate them, and exiting 0 here would report "clean" having compiled nothing.
[ "${#CRATES[@]}" -gt 0 ] || {
  echo "rust: refusing to pass - the crate list came back EMPTY (see rust-crates.sh)" >&2
  exit 1
}

rc=0
ran=() advisory=()

for crate in "${CRATES[@]}"; do
  name="$(basename "$crate")"

  # --locked so CI fails on a stale Cargo.lock instead of silently resolving a newer
  # dependency than the one committed -- the lockfiles ARE tracked here.
  if cargo test --manifest-path "$crate/Cargo.toml" --locked --quiet; then
    echo "cargo test: $name PASSED"
    ran+=("test:$name")
  else
    echo "cargo test: $name FAILED" >&2
    ran+=("test:$name")
    rc=1
  fi

  # --all-targets so tests and benches are linted too, not just the bin/lib.
  if cargo clippy --manifest-path "$crate/Cargo.toml" --locked --all-targets --quiet -- -D warnings 2>/dev/null; then
    echo "cargo clippy: $name clean"
    ran+=("clippy:$name")
  elif [ "$CLIPPY_GATE" = 1 ]; then
    cargo clippy --manifest-path "$crate/Cargo.toml" --locked --all-targets -- -D warnings >&2
    echo "cargo clippy: $name FAILED (CLIPPY_GATE=1)" >&2
    rc=1
  else
    n="$(cargo clippy --manifest-path "$crate/Cargo.toml" --locked --all-targets --message-format short 2>&1 | grep -c 'warning:' || true)"
    echo "cargo clippy: $name $n warnings (advisory; CLIPPY_GATE=1 to enforce)"
    advisory+=("clippy:$name")
  fi

  if cargo fmt --manifest-path "$crate/Cargo.toml" --check --quiet 2>/dev/null; then
    echo "cargo fmt: $name clean"
    ran+=("fmt:$name")
  elif [ "$RUSTFMT_GATE" = 1 ]; then
    cargo fmt --manifest-path "$crate/Cargo.toml" --check >&2
    echo "cargo fmt: $name FAILED (RUSTFMT_GATE=1)" >&2
    rc=1
  else
    echo "cargo fmt: $name would reformat (advisory; RUSTFMT_GATE=1 to enforce)"
    advisory+=("fmt:$name")
  fi
done

# Say what actually RAN, and name the crates -- lint.sh's argument applies here with
# teeth, because "rust: ok" over an empty or half-skipped crate list is precisely the
# silent success this gate replaces.
printf 'rust: %d crate(s): %s' "${#CRATES[@]}" "$(IFS=,; echo "${CRATES[*]}")"
printf '\n      ran %s' "$(IFS=,; echo "${ran[*]:-none}")"
[ "${#advisory[@]}" -gt 0 ] && printf '; ADVISORY (not enforced): %s' "$(IFS=,; echo "${advisory[*]}")"
printf '\n'

exit $rc
