#!/usr/bin/env bash
# The Rust gate. Single entry point for `make -C tests test-rust` and the CI rust job,
# for the same reason lint.sh is shared: a gate that differs between local and CI gets
# ignored the first time it disagrees.
#
# WHY THIS EXISTS
# ---------------
# The crates in this repo (notes-cli, agent-panel, agent-web, hub-core, hub-tui, timebox) carry
# in-tree tests between them, and until this file NONE of them ran anywhere. The CI
# workflow had four jobs and zero cargo. The failure was silent in both directions:
# nothing ran the tests, and build_local_rust_tools() in the installer treats a build
# failure as non-fatal on purpose (so a broken install still proceeds), leaving the
# PREVIOUS binary on PATH. So a crate could stop compiling and the only symptom would be
# a tool that quietly kept behaving like an older version.
#
# THE GATES
# ---------
# cargo test and cargo fmt (--all, so a workspace checks its member crates) block on every
# run. cargo clippy blocks too, unless CLIPPY=0: the CI rust job sets that on pull
# requests and runs clippy on main pushes, the schedule and a manual run, where a red stops
# the line (docs/ci.md). Clippy is a full second compile, the slowest step of a PR's rust
# job; a new lint that lands is caught on the next main push.
CLIPPY="${CLIPPY:-1}"

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

# One Rust version for every run, local and CI: tests/rust-toolchain. Each release adds
# clippy lints, so a gate on "whatever stable is installed" goes red when a runner image
# moves, on a commit that changed no Rust (main, 2026-11-13: clippy 0.1.99 in CI, 0.1.93
# here). Bump the file in a PR that fixes what the new version finds; it runs every crate.
RUSTUP_TOOLCHAIN="$(<tests/rust-toolchain)"
export RUSTUP_TOOLCHAIN
# A cargo with no rustup (a distro package) cannot honor the pin, so it fails here rather
# than checking with a different clippy.
if ! out=$(rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal -c clippy,rustfmt 2>&1); then
  printf '%s\nrust: cannot install toolchain %s (tests/rust-toolchain)\n' "$out" "$RUSTUP_TOOLCHAIN" >&2
  exit 1
fi

# Named crates (the CI pick, tests/pick.sh rust) or, with none, every tracked crate.
if [ $# -gt 0 ]; then
  CRATES=("$@")
else
  mapfile -t CRATES < <(tests/rust-crates.sh)
fi

# An empty list is a BROKEN GATE, not a clean tree -- the exact bug this whole file was
# written to close. Six crates are tracked; zero can only mean rust-crates.sh could not
# enumerate them, and exiting 0 here would report "clean" having compiled nothing. A pick that
# names no crate never calls this script (the CI rust job says "no crate picked" instead).
[ "${#CRATES[@]}" -gt 0 ] || {
  echo "rust: refusing to pass - the crate list came back EMPTY (see rust-crates.sh)" >&2
  exit 1
}

rc=0
ran=()

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
  if [ "$CLIPPY" = 1 ]; then
    ran+=("clippy:$name")
    if cargo clippy --manifest-path "$crate/Cargo.toml" --locked --all-targets --quiet -- -D warnings; then
      echo "cargo clippy: $name clean"
    else
      echo "cargo clippy: $name FAILED" >&2
      rc=1
    fi
  fi

  ran+=("fmt:$name")
  if cargo fmt --all --manifest-path "$crate/Cargo.toml" --check; then
    echo "cargo fmt: $name clean"
  else
    echo "cargo fmt: $name FAILED (run: cargo fmt --all --manifest-path $crate/Cargo.toml)" >&2
    rc=1
  fi
done

# Say what actually RAN, and name the crates -- lint.sh's argument applies here with
# teeth, because "rust: ok" over an empty or half-skipped crate list is precisely the
# silent success this gate replaces.
printf 'rust: %d crate(s): %s' "${#CRATES[@]}" "$(IFS=,; echo "${CRATES[*]}")"
printf '\n      ran %s' "$(IFS=,; echo "${ran[*]:-none}")"
[ "$CLIPPY" = 1 ] || printf '; clippy skipped (CLIPPY=0)'
printf '\n'

exit $rc
