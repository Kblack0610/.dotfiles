#!/usr/bin/env bats
# tests/rust.sh's crate pool (RUST_JOBS): crates gate at once up to the pool size, print in crate
# order, and one crate's failure reds the gate while the others still run. Over a stub cargo; the
# real toolchain path is prepush_hook.bats.

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  REPO="$(cd "$BATS_TEST_DIRNAME/../.." && pwd -P)"
  W="$BATS_TEST_TMPDIR/w"
  mkdir -p "$W/tests" "$W/c/a" "$W/c/b"
  cp "$REPO/tests/rust.sh" "$REPO/tests/rust-toolchain" "$W/tests/"
  bin="$BATS_TEST_TMPDIR/bin"
  mkdir -p "$bin"
  # rustup lists the pinned toolchain, so rust.sh installs nothing.
  printf '#!/usr/bin/env bash\n[ "$1 $2" = "toolchain list" ] && echo "%s-x86_64-unknown-linux-gnu"\nexit 0\n' "$(<"$REPO/tests/rust-toolchain")" >"$bin/rustup"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$bin/rustc"
  # cargo test for crate a reads the fifo that cargo test for crate b writes: both pass only when
  # they run at the same time. The timeouts bound a serial run, where neither side meets the other.
  cat >"$bin/cargo" <<'EOF'
#!/usr/bin/env bash
[ "$1" = test ] || [ "$1" = clippy ] || [ "$1" = fmt ] || exit 0
for a; do case $prev in --manifest-path) crate=$(basename "$(dirname "$a")") ;; esac; prev=$a; done
echo "stub $1 $crate"
[ "$1" = test ] || exit 0
[ "$crate" = "${STUB_FAIL:-}" ] && exit 1
[ -n "${STUB_FAIL:-}" ] && exit 0
case $crate in
  a) timeout 3 cat "$FIFO" >/dev/null ;;
  b) timeout 3 sh -c 'echo met >"$FIFO"' ;;
esac
EOF
  chmod +x "$bin"/*
  export FIFO="$BATS_TEST_TMPDIR/fifo" RUSTUP_HOME="$BATS_TEST_TMPDIR/rustup" PATH="$bin:$PATH"
  mkfifo "$FIFO"
}

gate() { (cd "$W" && tests/rust.sh c/a c/b); }

@test "a pool of two gates both crates at once, each line under its crate's name, the ran list in crate order" {
  RUST_JOBS=2 run gate
  assert_success
  assert_output --partial "[a] cargo test: a PASSED"
  assert_output --partial "[b] cargo test: b PASSED"
  assert_output --partial "[b] cargo fmt: b clean"
  assert_output --partial "ran test:a,clippy:a,fmt:a,test:b,clippy:b,fmt:b"
}

@test "negative control: the default pool of one runs the crates in the foreground one after another, so the fifo pair never meets" {
  run --separate-stderr gate
  assert_failure 1
  [[ "$stderr" == *"cargo test: a FAILED"* ]]
  assert_output --partial "cargo fmt: a clean"
  refute_output --partial "[a]"
}

@test "one crate's failure reds the gate and the other crate still runs every step" {
  STUB_FAIL=b RUST_JOBS=2 run gate
  assert_failure 1
  assert_output --partial "[b] cargo test: b FAILED"
  assert_output --partial "[b] cargo fmt: b clean"
  assert_output --partial "[a] cargo test: a PASSED"
  assert_output --partial "[a] cargo fmt: a clean"
}

@test "a RUST_JOBS that is not a positive integer is refused before any crate runs" {
  RUST_JOBS=0 run gate
  assert_failure 1
  assert_output --partial "RUST_JOBS must be a positive integer"
  refute_output --partial "stub test"
}
