#!/usr/bin/env bats
# tests/docker.sh builds its image once: the tag ends in a hash of what the image is built
# from, and an image present under that tag is not built again (CI restores it from cache).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  T="$BATS_TEST_TMPDIR/repo"
  mkdir -p "$T/tests/vendor/bats-core/bin" "$T/.local/src/tmux/patched" "$T/bin"
  cp "$BATS_TEST_DIRNAME/../docker.sh" "$T/tests/docker.sh"
  echo 'FROM scratch' > "$T/tests/Dockerfile"
  echo 1.99.1 > "$T/tests/rust-toolchain"
  echo 'patch' > "$T/.local/src/tmux/patched/a.patch"
  printf '#!/bin/sh\n' > "$T/tests/vendor/bats-core/bin/bats"
  chmod +x "$T/tests/vendor/bats-core/bin/bats"
  LOG="$BATS_TEST_TMPDIR/docker.log"
  # A fake docker: logs each call; `image inspect` succeeds only when $PRESENT exists. A detached
  # run prints a container id, and an exec exits $EXEC_RC.
  cat > "$T/bin/docker" <<FAKE
#!/bin/sh
echo "\$*" >> "$LOG"
[ "\$1 \$2" = "image inspect" ] && { [ -e "$BATS_TEST_TMPDIR/present" ]; exit; }
[ "\$1 \$2" = "image ls" ] && { cat "$BATS_TEST_TMPDIR/images" 2>/dev/null; exit 0; }
[ "\$1 \$2" = "run -d" ] && { echo cid1; exit 0; }
[ "\$1" = exec ] && exit "\${EXEC_RC:-0}"
exit 0
FAKE
  chmod +x "$T/bin/docker"
  export DOCKER="$T/bin/docker"
  unset COCKPIT_TEST_IMAGE TMUX_REF TMUX_STOCK FZF_REF
}

@test "the tag changes when the Dockerfile, the context or a build arg changes" {
  run "$T/tests/docker.sh" --image
  assert_success
  base="$output"
  [[ "$base" =~ ^cockpit-tests:tmux3\.8-fzf[0-9.]+-[0-9a-f]{12}$ ]]
  run "$T/tests/docker.sh" --image
  assert_output "$base"
  echo 'RUN true' >> "$T/tests/Dockerfile"
  run "$T/tests/docker.sh" --image
  refute_output "$base"
  df="$output"
  echo more >> "$T/.local/src/tmux/patched/a.patch"
  run "$T/tests/docker.sh" --image
  refute_output "$df"
  ctx="$output"
  TMUX_REF=3.4 run "$T/tests/docker.sh" --image
  refute_output "$ctx"
}

@test "--build builds a missing image and exits without running the suite" {
  run "$T/tests/docker.sh" --build
  assert_success
  run grep -c '^build ' "$LOG"
  assert_output 1
  run grep -c '^run ' "$LOG"
  assert_output 0
}

@test "an image present under its tag is not built again" {
  touch "$BATS_TEST_TMPDIR/present"
  run "$T/tests/docker.sh" --build
  assert_success
  assert_output --partial 'present, not rebuilt'
  run grep -c '^build ' "$LOG"
  assert_output 0
}

@test "an image named by COCKPIT_TEST_IMAGE is always built" {
  touch "$BATS_TEST_TMPDIR/present"
  COCKPIT_TEST_IMAGE=mine:latest run "$T/tests/docker.sh" --build
  assert_success
  run grep -c '^build .*-t mine:latest' "$LOG"
  assert_output 1
}

@test "a new build drops the same tmux/fzf pair's older images, and nothing else" {
  run "$T/tests/docker.sh" --image
  new="$output"
  printf '%s\n' "${new%-*}-0123456789ab" "$new" "cockpit-tests:tmux3.4-fzf0.74.1-0123456789ab" \
    > "$BATS_TEST_TMPDIR/images"
  run "$T/tests/docker.sh" --build
  assert_success
  run grep '^rmi' "$LOG"
  assert_output "rmi ${new%-*}-0123456789ab"
}

@test "each kind has its own tag, the full one keeps the old shape, and --build targets the kind" {
  run "$T/tests/docker.sh" --image
  full="$output"
  [[ "$full" =~ ^cockpit-tests:tmux3\.8- ]]
  TEST_IMAGE_KIND=full run "$T/tests/docker.sh" --image
  assert_output "$full"
  TEST_IMAGE_KIND=lean run "$T/tests/docker.sh" --image
  [[ "$output" =~ ^cockpit-tests:lean-tmux3\.8-fzf[0-9.]+-[0-9a-f]{12}$ ]]
  [ "${output#cockpit-tests:lean-}" = "${full#cockpit-tests:}" ]
  TEST_IMAGE_KIND=rust run "$T/tests/docker.sh" --image
  [[ "$output" =~ ^cockpit-tests:rust-tmux3\.8- ]]
  TEST_IMAGE_KIND=lean run "$T/tests/docker.sh" --build
  assert_success
  run grep -c '^build .*--target lean ' "$LOG"
  assert_output 1
  run "$T/tests/docker.sh" --build
  run grep -c '^build .*--target full ' "$LOG"
  assert_output 1
}

@test "a kind that is not a Dockerfile stage is refused" {
  TEST_IMAGE_KIND=slim run "$T/tests/docker.sh" --image
  assert_failure 2
  assert_output --partial 'lean, rust or full'
}

@test "a new build of one kind leaves the other kinds' images alone" {
  TEST_IMAGE_KIND=lean run "$T/tests/docker.sh" --image
  lean="$output"
  run "$T/tests/docker.sh" --image
  full="$output"
  printf '%s\n' "${lean%-*}-0123456789ab" "${full%-*}-0123456789ab" "$full" > "$BATS_TEST_TMPDIR/images"
  TEST_IMAGE_KIND=lean run "$T/tests/docker.sh" --build
  assert_success
  run grep '^rmi' "$LOG"
  assert_output "rmi ${lean%-*}-0123456789ab"
}

@test "tests/Dockerfile defines every stage docker.sh can target" {
  for kind in lean rust full; do
    grep -qE "^FROM .* AS $kind\$" "$BATS_TEST_DIRNAME/../Dockerfile" || fail "no stage named $kind in tests/Dockerfile"
  done
}

# In CI the command runs by docker exec in a detached container, so the step never waits on the
# container's exit and removal (ar-5740); outside CI it is one plain docker run.
@test "in CI a command runs by docker exec in a detached container and keeps its exit status" {
  touch "$BATS_TEST_TMPDIR/present"
  CI=true EXEC_RC=3 run "$T/tests/docker.sh" --run x y
  assert_failure 3
  run grep -E '^run -d --entrypoint sleep .* infinity$' "$LOG"
  assert_success
  run grep -cxF 'exec cid1 /usr/local/bin/test-entry x y' "$LOG"
  assert_output 1
}

@test "outside CI a command is one docker run, with no exec" {
  touch "$BATS_TEST_TMPDIR/present"
  CI= run "$T/tests/docker.sh" --run x y
  assert_success
  run grep -cE '^run .* x y$' "$LOG"
  assert_output 1
  run grep -cE '^(exec|run -d) ' "$LOG"
  assert_output 0
}
