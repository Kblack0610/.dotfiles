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
# run. cargo clippy blocks too, unless CLIPPY=0 (a local shortcut: CI never sets it, so a
# lint reds the pull request, not main). Clippy is a full second compile.
CLIPPY="${CLIPPY:-1}"
# RUST_TESTS=0 skips cargo test: .githooks/pre-push runs only the lint steps, the tests stay in CI.
RUST_TESTS="${RUST_TESTS:-1}"

# No `-e`: this script runs several gates over several crates and accumulates rc, so one
# failure must not abort the rest. That makes the explicit `|| exit` on cd load-bearing.
set -uo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.." || exit 1

# The pinned toolchain is ready when it is listed and its cargo, rustc, clippy and rustfmt all
# run. Listed alone is not enough: a runner image (ubuntu-24.04 20261103.629) lists 1.99.1 while
# rustup calls it partial, and installing over it while another install runs fails with
# "detected conflict". The list check comes first so the proxy never sees an unlisted toolchain,
# which a rustup that ignores RUSTUP_AUTO_INSTALL would download. `--toolchain-ready` answers
# only that, for tests that need the real toolchain (tests/unit/prepush_hook.bats).
toolchain_ready() {
  local tc
  tc="$(<tests/rust-toolchain)"
  command -v rustup >/dev/null 2>&1 && rustup toolchain list 2>/dev/null | grep -q "^$tc" || return 1
  RUSTUP_AUTO_INSTALL=0 RUSTUP_TOOLCHAIN="$tc" bash -c \
    'cargo --version && rustc --version && cargo clippy --version && cargo fmt --version' >/dev/null 2>&1
}
if [ "${1:-}" = --toolchain-ready ]; then
  toolchain_ready
  exit
fi

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
# than checking with a different clippy. A ready toolchain is not installed again, so a push
# needs no network. An install holds a lock in RUSTUP_HOME and checks again once it has it: two
# installs of one toolchain at once corrupt it, and this machine pushes from many worktrees at
# once. The wait is bounded (10 min, more than a cold install takes) and says what it waits on.
if ! toolchain_ready; then
  lock="${RUSTUP_HOME:-$HOME/.rustup}/dotfiles-install.lock"
  if command -v flock >/dev/null 2>&1 && mkdir -p "${lock%/*}" && exec 9>"$lock"; then
    if ! flock -n 9; then
      echo "rust: waiting for another toolchain install ($lock)" >&2
      flock -w 600 9 || { echo "rust: gave up after 600s waiting on $lock" >&2; exit 1; }
    fi
  fi
  if ! toolchain_ready &&
    ! out=$(rustup toolchain install "$RUSTUP_TOOLCHAIN" --profile minimal -c clippy,rustfmt 2>&1 9>&-); then
    printf '%s\nrust: cannot install toolchain %s (tests/rust-toolchain)\n' "$out" "$RUSTUP_TOOLCHAIN" >&2
    exit 1
  fi
  exec 9>&-
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

# RUST_JOBS: how many crates gate at once. One crate's build leaves most of a runner's cores idle
# (its own crate compiles alone at the end), and the CI rust job is the critical path of a picked
# run: 3 crates one after another were 197 s of a 284 s job (run 44958645304). CI sets it; a
# local push keeps the default, 1, because many worktrees push at once on this machine.
RUST_JOBS="${RUST_JOBS:-1}"
[[ "$RUST_JOBS" =~ ^[1-9][0-9]*$ ]] || { echo "rust: RUST_JOBS must be a positive integer, got '$RUST_JOBS'" >&2; exit 1; }

# gate_crate <dir> <ran file>: test, clippy and fmt one crate, appending each step it ran to the
# ran file. Exit 1 when any step failed; the other steps still run and report.
gate_crate() {
  local crate="$1" ranf="$2" name rc=0
  name="$(basename "$crate")"

  # --locked so CI fails on a stale Cargo.lock instead of silently resolving a newer
  # dependency than the one committed -- the lockfiles ARE tracked here.
  if [ "$RUST_TESTS" = 1 ]; then
    echo "test:$name" >>"$ranf"
    if cargo test --manifest-path "$crate/Cargo.toml" --locked --quiet; then
      echo "cargo test: $name PASSED"
    else
      echo "cargo test: $name FAILED" >&2
      rc=1
    fi
  fi

  # --all-targets so tests and benches are linted too, not just the bin/lib.
  if [ "$CLIPPY" = 1 ]; then
    echo "clippy:$name" >>"$ranf"
    if cargo clippy --manifest-path "$crate/Cargo.toml" --locked --all-targets --quiet -- -D warnings; then
      echo "cargo clippy: $name clean"
    else
      echo "cargo clippy: $name FAILED" >&2
      rc=1
    fi
  fi

  echo "fmt:$name" >>"$ranf"
  if cargo fmt --all --manifest-path "$crate/Cargo.toml" --check; then
    echo "cargo fmt: $name clean"
  else
    echo "cargo fmt: $name FAILED (run: cargo fmt --all --manifest-path $crate/Cargo.toml)" >&2
    rc=1
  fi
  return $rc
}

# Each crate writes its output and exit status to files of its own, printed in crate order once
# all are done, so crates that run at once never interleave. The status goes to a file because
# `wait -n` frees a pool slot without saying which crate finished.
out="$(mktemp -d)" || exit 1
trap 'rm -rf "$out"' EXIT
for i in "${!CRATES[@]}"; do
  while [ "$(jobs -rp | wc -l)" -ge "$RUST_JOBS" ]; do wait -n; done
  (
    gate_crate "${CRATES[$i]}" "$out/$i.ran" >"$out/$i.log" 2>&1
    echo $? >"$out/$i.rc"
  ) &
done
wait

rc=0
ran=()
for i in "${!CRATES[@]}"; do
  cat "$out/$i.log"
  [ -f "$out/$i.ran" ] && mapfile -t -O "${#ran[@]}" ran <"$out/$i.ran"
  # No status file means the crate's subshell died before writing one: a failure, never a pass.
  [ "$(cat "$out/$i.rc" 2>/dev/null)" = 0 ] || rc=1
done

# Say what actually RAN, and name the crates -- lint.sh's argument applies here with
# teeth, because "rust: ok" over an empty or half-skipped crate list is precisely the
# silent success this gate replaces.
printf 'rust: %d crate(s): %s' "${#CRATES[@]}" "$(IFS=,; echo "${CRATES[*]}")"
printf '\n      ran %s' "$(IFS=,; echo "${ran[*]:-none}")"
[ "$CLIPPY" = 1 ] || printf '; clippy skipped (CLIPPY=0)'
[ "$RUST_TESTS" = 1 ] || printf '; tests skipped (RUST_TESTS=0)'
printf '\n'

exit $rc
