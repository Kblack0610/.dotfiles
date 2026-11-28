#!/usr/bin/env bats
# watch_red_lines (.local/lib/sentinel-watch.sh): the red lines a watch's evidence names, the first of
# which is fleet-bench triage's why. A status-row probe (vendor-check) names its worst row, not its last.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/lib/sentinel-watch.sh"
  OUT="$HOME/w.out"
}

@test "a RED line of a stage probe is named before any status row" {
  printf 'TRIP exit 1 (want 0)\nOK  a.yml: success\nRED b.yml: failure\nRED c.yml: failure\nOK  d: none\n' > "$OUT"
  run watch_red_lines "$OUT"
  assert_success
  assert_output $'RED b.yml: failure\nRED c.yml: failure'
}

@test "a status-row probe names its EXPIRED or NO_CREDS row, not a gap row, a LOW row or the last line" {
  printf "TRIP exit 2 (want 0)\nghost NO_CREDS probe=listed detail='not in rbw; gap: add-ghost-login'\naws EXPIRED probe=cmd detail='sso token expired'\nstripe OK probe=http\nollama-cloud LOW probe=http detail='timeout'\n" > "$OUT"
  run watch_red_lines "$OUT"
  assert_success
  assert_output 'aws EXPIRED probe=cmd'
}

@test "a status-row probe with only a LOW trip names that row, not a later OK one" {
  printf "TRIP exit 1 (want 0)\nollama-cloud LOW probe=http detail='timeout'\nstripe OK probe=http\n" > "$OUT"
  run watch_red_lines "$OUT"
  assert_success
  assert_output 'ollama-cloud LOW probe=http'
}

@test "negative control: a probe with no status row names its last non-blank line" {
  printf 'TRIP exit 1 (want 0)\npod web-1 failed\n\n' > "$OUT"
  run watch_red_lines "$OUT"
  assert_success
  assert_output 'pod web-1 failed'
}
