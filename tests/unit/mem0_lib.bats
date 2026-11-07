#!/usr/bin/env bats
# mem0.sh: the one mem0 config reader and the one key reader. sops is stubbed, no network.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  LIB="$BATS_TEST_DIRNAME/../../.local/lib/mem0.sh"
  ENVF="$BATS_TEST_TMPDIR/mem0.env"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  unset MEM0_BASE_URL MEM0_USER_ID MEM0_SECRET MEM0_ENV
}

stub_sops() { printf '#!/bin/sh\necho "MEM0_API_KEY: \\"%s\\""\n' "$1" > "$BATS_TEST_TMPDIR/bin/sops"; chmod +x "$BATS_TEST_TMPDIR/bin/sops"; }

@test "mem0_load exports the three names, expanding \$HOME in the secret path" {
  printf 'MEM0_BASE_URL=https://mem0.test\nMEM0_USER_ID=me\nMEM0_SECRET=$HOME/s.yaml\n' > "$ENVF"
  run bash -c ". '$LIB'; mem0_load '$ENVF' && bash -c 'echo \$MEM0_BASE_URL \$MEM0_USER_ID \$MEM0_SECRET'"
  assert_success
  assert_output "https://mem0.test me $HOME/s.yaml"
}

@test "mem0_load honours MEM0_ENV, and names a missing file or a missing variable" {
  printf 'MEM0_BASE_URL=https://mem0.test\nMEM0_USER_ID=me\n' > "$ENVF"
  MEM0_ENV="$ENVF" run bash -c ". '$LIB'; mem0_load"
  assert_failure
  assert_output --partial "needs MEM0_BASE_URL, MEM0_USER_ID and MEM0_SECRET"
  run bash -c ". '$LIB'; mem0_load '$BATS_TEST_TMPDIR/none'"
  assert_failure
  assert_output --partial "no mem0 config at $BATS_TEST_TMPDIR/none"
}

@test "mem0_key prints an m0sk_ key and refuses anything else" {
  stub_sops m0sk_abc
  MEM0_SECRET=/x run bash -c ". '$LIB'; mem0_key"
  assert_success
  assert_output m0sk_abc
  stub_sops "rbw login password"
  MEM0_SECRET=/x run bash -c ". '$LIB'; mem0_key"
  assert_failure
  assert_output --partial "no mem0 key could be read from /x"
}
