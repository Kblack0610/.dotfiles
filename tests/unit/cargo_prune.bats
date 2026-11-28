#!/usr/bin/env bats
# tests/cargo-prune.sh: main's cargo cache keeps third-party artifacts and the .crate files, and
# drops what every run rebuilds or unpacks again (ar-4235).

bats_require_minimum_version 1.5.0

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  SUBJECT="$BATS_TEST_DIRNAME/../cargo-prune.sh"
  R="$BATS_TEST_TMPDIR/repo"
  h=0123456789abcdef
  mkdir -p "$R/.local/src/hub-core/tests" "$R/.local/src/hub-tui" "$R/.cargo-ci/registry/src/x" "$R/.cargo-ci/registry/cache"
  printf '[package]\nname = "hub-core"\n[lib]\nname = "hub_lib"\n\n[dependencies]\nserde = "1"\n' >"$R/.local/src/hub-core/Cargo.toml"
  # A fixture manifest deeper down names nothing, or serde's artifacts would go.
  mkdir -p "$R/.local/src/hub-core/tests/fixtures/dep"
  printf '[package]\nname = "serde"\n' >"$R/.local/src/hub-core/tests/fixtures/dep/Cargo.toml"
  printf '[package]\nname = "hub-tui"\n[[bin]]\nname = "hub"\n' >"$R/.local/src/hub-tui/Cargo.toml"
  : >"$R/.local/src/hub-core/tests/widget_doc.rs"
  : >"$R/.cargo-ci/registry/cache/serde-1.0.0.crate"
  : >"$R/.cargo-ci/registry/src/x/lib.rs"
  t="$R/.local/src/hub-tui/target/debug"
  mkdir -p "$t/deps" "$t/.fingerprint/hub-core-$h" "$t/.fingerprint/serde-$h" "$t/build/hub-core-$h" \
    "$t/.fingerprint/hub-core-macros-$h" "$t/incremental/x"
  touch "$t/hub" "$t/hub.d" "$t/deps/hub-$h" "$t/deps/hub_core-$h.d" "$t/deps/libhub_core-$h.rlib" \
    "$t/deps/libhub_core-$h.rmeta" "$t/deps/libhub_lib-$h.rlib" "$t/deps/widget_doc-$h" "$t/deps/libserde-$h.rlib" \
    "$t/deps/libhub_core_macros-$h.so"
}

@test "our own artifacts, the uplifted binaries and registry/src go" {
  run "$SUBJECT" "$R"
  assert_success
  assert_output --partial "cargo-prune: the artifacts of 5 names of ours"
  local f
  for f in hub hub.d deps/hub-$h deps/hub_core-$h.d deps/libhub_core-$h.rlib deps/libhub_core-$h.rmeta deps/libhub_lib-$h.rlib \
    deps/widget_doc-$h .fingerprint/hub-core-$h build/hub-core-$h incremental; do
    [ ! -e "$t/$f" ] || fail "kept $f"
  done
  [ ! -e "$R/.cargo-ci/registry/src" ] || fail "kept registry/src"
}

@test "negative control: third-party artifacts, a dependency named like ours, and the .crate files stay" {
  run "$SUBJECT" "$R"
  assert_success
  local f
  for f in deps/libserde-$h.rlib .fingerprint/serde-$h .fingerprint/hub-core-macros-$h deps/libhub_core_macros-$h.so; do
    [ -e "$t/$f" ] || fail "removed $f"
  done
  [ -e "$R/.cargo-ci/registry/cache/serde-1.0.0.crate" ] || fail "removed the .crate file"
}

@test "a tree with no crate is an error, not an empty prune" {
  rm -rf "$R/.local/src"/*
  run "$SUBJECT" "$R"
  assert_failure
  assert_output --partial "no crate found"
}
