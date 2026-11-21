#!/usr/bin/env bats
# .githooks/pre-push: the offline steps of tests.yml, picked by the pushed paths. Three layers:
# the hook paired with tests.yml's job list; its dispatch, over stub tools; and negative controls
# through the real lint.sh, rust.sh and pick.sh, each refused by the hook and the clean one let through.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  HOOK="$REPO/.githooks/pre-push"
  WF="$REPO/.github/workflows/tests.yml"
  W="$BATS_TEST_TMPDIR/w"
  CALLS="$BATS_TEST_TMPDIR/calls"
  : >"$CALLS"
  unset PREPUSH_CHANGED GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_PREFIX GIT_COMMON_DIR
  export CARGO_TARGET_DIR="$BATS_TEST_TMPDIR/target"
  # The suite HOME is a throwaway one: the toolchains are the account's (RUSTUP_HOME, CARGO_HOME; rustup proxies need both).
  export RUSTUP_HOME="${RUSTUP_HOME:-${ACCOUNT_HOME:-$HOME}/.rustup}" CARGO_HOME="${CARGO_HOME:-${ACCOUNT_HOME:-$HOME}/.cargo}"
}

# mkrepo: an empty repo with the hook, one commit, and origin/main at it.
mkrepo() {
  mkdir -p "$W/.githooks" "$W/tests/unit" "$W/.local/lib"
  cp "$HOOK" "$W/.githooks/pre-push"
  git -C "$W" init -q -b main
  git -C "$W" config user.name t && git -C "$W" config user.email t@t
  printf 'x\n' >"$W/README"
  git -C "$W" add -A && git -C "$W" commit -qm init
  git -C "$W" update-ref refs/remotes/origin/main HEAD
}

# stub <tests/relative path> <body>: an executable stand-in for one of the repo's tools.
stub() {
  mkdir -p "$(dirname "$W/$1")"
  printf '#!/usr/bin/env bash\n%s\n' "$2" >"$W/$1"
  chmod +x "$W/$1"
}

# stubs: every tool the hook calls, each logging its call; the callers override one.
stubs() {
  stub tests/lint-files.sh 'printf "%s\n" a.sh b.sh'
  stub tests/lint.sh 'echo "lint $*" >>"$CALLS"'
  stub tests/pick.sh 'echo "$STUB_CRATES"; echo "$1: picked" >&2'
  stub tests/rust.sh 'echo "rust CLIPPY=$CLIPPY RUST_TESTS=$RUST_TESTS $*" >>"$CALLS"'
  export CALLS STUB_CRATES=
}

hook() { (cd "$W" && .githooks/pre-push </dev/null); }

@test "every job of tests.yml is placed in the hook header, run or CI only, and no stale id is" {
  jobs=$(sed -nE '/^jobs:$/,$ s/^  ([A-Za-z0-9_][A-Za-z0-9_-]*):$/\1/p' "$WF" | sort)
  placed=$(sed -nE 's/^#   (runs: *|CI only: *)//p' "$HOOK" | tr -s ' ' '\n' | grep . | sort)
  [ -n "$jobs" ] && [ -n "$placed" ]
  run diff <(echo "$jobs") <(echo "$placed")
  assert_success
}

@test "the steps the hook runs are the commands tests.yml runs" {
  grep -q 'tests/docker.sh lint' "$WF"
  grep -q 'tests/pick.sh rust' "$WF"
  grep -q 'make -C tests test-rust' "$WF"
  grep -q 'tests/lint.sh --only' "$HOOK"
  grep -q 'tests/rust.sh' "$HOOK"
  grep -q 'tests/pick.sh rust HEAD' "$HOOK"
}

@test "a shell-only change lints the changed shell files and runs no rust step" {
  mkrepo; stubs
  PREPUSH_CHANGED=$'a.sh\nREADME' run --separate-stderr hook
  assert_success
  run cat "$CALLS"
  assert_line "lint --only a.sh"
  refute_line --partial "rust "
}

@test "a changed crate runs fmt and clippy, never its tests" {
  mkrepo; stubs
  export STUB_CRATES=.local/src/c1
  PREPUSH_CHANGED=.local/src/c1/main.rs run hook
  assert_success
  run cat "$CALLS"
  assert_line "rust CLIPPY=1 RUST_TESTS=0 .local/src/c1"
}

@test "a pick that says full is left to CI and nothing runs for it" {
  mkrepo; stubs
  stub tests/pick.sh 'echo "full: the change touches the rust gate" >&2; echo .local/src/c1'
  PREPUSH_CHANGED=tests/Makefile run --separate-stderr hook
  assert_success
  [[ "$stderr" == *"left to CI"* ]]
  ! grep -q "rust " "$CALLS"
}

@test "a red step refuses the push and prints its output" {
  mkrepo; stubs
  stub tests/lint.sh 'echo "a.sh: the finding"; exit 1'
  PREPUSH_CHANGED=a.sh run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"lint FAILED"* && "$stderr" == *"a.sh: the finding"* && "$stderr" == *"refused"* ]]
}

@test "ledger: a launch with no row in the private launch table refuses the push; no overlay or no scanned path skips it" {
  mkrepo; stubs
  stub .local/bin/fleet-bench 'echo "fleet-bench $* $LEDGER_PIPELINES" >>"$CALLS"; echo "launch with no PIPELINES.md row: x"; exit 1'
  export DOTFILES_PRIVATE="$BATS_TEST_TMPDIR/priv"
  PREPUSH_CHANGED=README run --separate-stderr hook
  assert_success
  mkdir -p "$DOTFILES_PRIVATE/.config/agentctl"
  PREPUSH_CHANGED=.local/bin/x run --separate-stderr hook
  assert_success
  ! grep -q fleet-bench "$CALLS"
  : >"$DOTFILES_PRIVATE/.config/agentctl/PIPELINES.md"
  PREPUSH_CHANGED=README run --separate-stderr hook
  assert_success
  PREPUSH_CHANGED=.local/bin/x run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"ledger (launch table: $DOTFILES_PRIVATE) FAILED"* && "$stderr" == *"launch with no PIPELINES.md row: x"* ]]
  run cat "$CALLS"
  assert_line "fleet-bench ledger --unlisted $DOTFILES_PRIVATE/.config/agentctl/PIPELINES.md"
}

@test "the push range is read from stdin: a new branch is checked against main, a delete and another ref are not" {
  mkrepo; stubs
  printf 'y\n' >"$W/a.sh" && git -C "$W" add a.sh && git -C "$W" commit -qm a
  sha=$(git -C "$W" rev-parse HEAD) zero=0000000000000000000000000000000000000000
  run --separate-stderr bash -c "cd '$W' && printf 'refs/heads/b $sha refs/heads/b $zero\n' | .githooks/pre-push"
  assert_success
  run cat "$CALLS"
  assert_line "lint --only a.sh"
  : >"$CALLS"
  run --separate-stderr bash -c "cd '$W' && printf 'refs/heads/b $zero refs/heads/b $sha\n' | .githooks/pre-push"
  assert_success
  [ ! -s "$CALLS" ]
  run --separate-stderr bash -c "cd '$W' && printf 'refs/heads/o %s refs/heads/o $zero\n' 1111111111111111111111111111111111111111 | .githooks/pre-push"
  assert_success
  [[ "$stderr" == *"is not the checked-out HEAD"* ]]
  [ ! -s "$CALLS" ]
}

# have_toolchain: the pinned rust toolchain runs, by rust.sh's own check (the fast tier's runner
# may have the rustup proxy only, or a listed but partial toolchain). A test never installs one.
have_toolchain() { "$REPO/tests/rust.sh" --toolchain-ready; }

# realrepo: the repo's real lint, rust and pick tools over a one-crate fixture.
realrepo() {
  mkrepo
  mkdir -p "$W/.local/src/tmux" "$W/.local/src/neg/src"
  for f in lint.sh lint-files.sh lint-head.awk pick.sh rust.sh rust-crates.sh rust-inputs.txt rust-toolchain; do
    cp "$REPO/tests/$f" "$W/tests/$f"
  done
  cp "$REPO/.shellcheckrc" "$W/"
  cp "$REPO/.local/lib/test-pick.sh" "$W/.local/lib/"
  : >"$W/tests/broad.txt"
  printf '@test "x" { true; }\n' >"$W/tests/unit/x.bats"
  printf '#!/usr/bin/env bash\n[[ "${BASH_SOURCE[0]}" != "$0" ]] && return 0\n' >"$W/.local/src/tmux/fleet.sh"
  printf '[package]\nname = "neg"\nversion = "0.1.0"\nedition = "2021"\n' >"$W/.local/src/neg/Cargo.toml"
  printf 'fn main() {\n    println!("hi");\n}\n' >"$W/.local/src/neg/src/main.rs"
  # the lockfile only the rust control needs; rust.sh passes --locked
  if have_toolchain; then (cd "$W/.local/src/neg" && RUSTUP_AUTO_INSTALL=0 RUSTUP_TOOLCHAIN=$(<"$REPO/tests/rust-toolchain") cargo generate-lockfile --offline -q); fi
  git -C "$W" add -A && git -C "$W" commit -qm base
  git -C "$W" update-ref refs/remotes/origin/main HEAD
}

@test "a command piped into head under pipefail is refused by the house rule, and the fixed file goes through" {
  realrepo
  printf '#!/usr/bin/env bash\nset -euo pipefail\nseq 1 9 | head -n 1\n' >"$W/bad.sh"
  git -C "$W" add bad.sh
  PREPUSH_CHANGED=bad.sh run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"lint FAILED"* && "$stderr" == *"bad.sh"* && "$stderr" == *"piped into head"* ]]
  printf '#!/usr/bin/env bash\nset -euo pipefail\nseq 1 9 | awk "NR<=1"\n' >"$W/bad.sh"
  PREPUSH_CHANGED=bad.sh run --separate-stderr hook
  assert_success
  [[ "$stderr" == *"lint ok"* ]]
}

@test "a shellcheck error is refused" {
  command -v shellcheck >/dev/null || skip "shellcheck is not installed on this host; CI runs it"
  realrepo
  printf '#!/usr/bin/env bash\nif true; then\n  echo hi\n' >"$W/bad.sh"
  git -C "$W" add bad.sh
  PREPUSH_CHANGED=bad.sh run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"bad.sh"* ]]
}

@test "rust.sh installs no toolchain that already runs; an unlisted one never reaches the proxy; a listed one whose clippy is missing is installed" {
  realrepo
  tc=$(<"$REPO/tests/rust-toolchain")
  bin="$BATS_TEST_TMPDIR/bin"; mkdir -p "$bin"
  printf '#!/usr/bin/env bash\necho "rustup $*" >>"$CALLS"\n[ "$1 $2" = "toolchain list" ] && [ -z "${STUB_UNLISTED:-}" ] && echo "%s-x86_64-unknown-linux-gnu"\nexit 0\n' "$tc" >"$bin/rustup"
  printf '#!/usr/bin/env bash\necho "cargo $*" >>"$CALLS"\n[ "$1 $2" = "clippy --version" ] && [ -n "${STUB_NO_CLIPPY:-}" ] && exit 1\nexit 0\n' >"$bin/cargo"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/rustc"
  chmod +x "$bin"/*
  export CALLS RUSTUP_HOME="$BATS_TEST_TMPDIR/rustup"
  PATH="$bin:$PATH" run --separate-stderr "$W/tests/rust.sh" --toolchain-ready
  assert_success
  PATH="$bin:$PATH" CLIPPY=1 RUST_TESTS=0 run --separate-stderr "$W/tests/rust.sh" .local/src/neg
  assert_success
  run ! grep -q 'toolchain install' "$CALLS"
  : >"$CALLS"
  STUB_UNLISTED=1 PATH="$bin:$PATH" run --separate-stderr "$W/tests/rust.sh" --toolchain-ready
  assert_failure
  run ! grep -q '^cargo' "$CALLS"
  STUB_NO_CLIPPY=1 PATH="$bin:$PATH" run --separate-stderr "$W/tests/rust.sh" --toolchain-ready
  assert_failure
  STUB_NO_CLIPPY=1 PATH="$bin:$PATH" CLIPPY=1 RUST_TESTS=0 run --separate-stderr "$W/tests/rust.sh" .local/src/neg
  assert_success
  grep -q "rustup toolchain install $tc --profile minimal -c clippy,rustfmt" "$CALLS"
  if command -v flock >/dev/null; then [ -e "$RUSTUP_HOME/dotfiles-install.lock" ]; fi
}

@test "a clippy sort_by hit is refused naming the crate, and a misformatted line is refused" {
  have_toolchain || skip "the pinned rust toolchain is not installed here; the rust job runs tests/rust.sh itself"
  realrepo
  printf 'fn main() {\n    let mut v = vec!["a", "bb"];\n    v.sort_by(|a, b| a.len().cmp(&b.len()));\n    println!("{v:?}");\n}\n' >"$W/.local/src/neg/src/main.rs"
  PREPUSH_CHANGED=.local/src/neg/src/main.rs run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"rust fmt+clippy"* && "$stderr" == *"FAILED"* && "$stderr" == *"clippy: neg FAILED"* ]]
  printf 'fn main() {  println!("hi") ;\n}\n' >"$W/.local/src/neg/src/main.rs"
  PREPUSH_CHANGED=.local/src/neg/src/main.rs run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"cargo fmt: neg FAILED"* ]]
  printf 'fn main() {\n    println!("hi");\n}\n' >"$W/.local/src/neg/src/main.rs"
  PREPUSH_CHANGED=.local/src/neg/src/main.rs run --separate-stderr hook
  assert_success
  [[ "$stderr" == *"rust fmt+clippy ok"* ]]
}

@test "the steps run without the repo variables git exports to a hook, so a test's git cannot reach the real repo" {
  mkrepo; stubs
  stub tests/lint.sh 'echo "lint GIT_DIR=${GIT_DIR-unset} GIT_INDEX_FILE=${GIT_INDEX_FILE-unset}" >>"$CALLS"'
  GIT_DIR="$W/.git" GIT_INDEX_FILE="$W/.git/index" PREPUSH_CHANGED=a.sh run hook
  assert_success
  run cat "$CALLS"
  assert_line "lint GIT_DIR=unset GIT_INDEX_FILE=unset"
}

@test "a merge of main into the branch does not bring main's changes into the check" {
  mkrepo; stubs
  git -C "$W" checkout -q -b feat
  printf 'y\n' >"$W/a.sh" && git -C "$W" add a.sh && git -C "$W" commit -qm a
  pushed=$(git -C "$W" rev-parse HEAD) zero=0000000000000000000000000000000000000000
  git -C "$W" checkout -q main
  printf 'z\n' >"$W/b.sh" && git -C "$W" add b.sh && git -C "$W" commit -qm b
  git -C "$W" update-ref refs/remotes/origin/main HEAD
  git -C "$W" checkout -q feat && git -C "$W" merge -q --no-edit main
  sha=$(git -C "$W" rev-parse HEAD)
  run --separate-stderr bash -c "cd '$W' && printf 'refs/heads/feat $sha refs/heads/feat $pushed\n' | .githooks/pre-push"
  assert_success
  run cat "$CALLS"
  assert_line "lint --only a.sh"
}

@test "a tests/lint-files.sh that fails refuses the push, and the seam says it is set" {
  mkrepo; stubs
  stub tests/lint-files.sh 'echo boom >&2; exit 1'
  PREPUSH_CHANGED=a.sh run --separate-stderr hook
  assert_failure 1
  [[ "$stderr" == *"lint-files.sh failed"* && "$stderr" == *"PREPUSH_CHANGED is set"* ]]
}
