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
  echo 'patch' > "$T/.local/src/tmux/patched/a.patch"
  printf '#!/bin/sh\n' > "$T/tests/vendor/bats-core/bin/bats"
  chmod +x "$T/tests/vendor/bats-core/bin/bats"
  LOG="$BATS_TEST_TMPDIR/docker.log"
  # A fake docker: logs each call; `image inspect` succeeds only when $PRESENT exists.
  cat > "$T/bin/docker" <<FAKE
#!/bin/sh
echo "\$*" >> "$LOG"
[ "\$1 \$2" = "image inspect" ] && { [ -e "$BATS_TEST_TMPDIR/present" ]; exit; }
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
