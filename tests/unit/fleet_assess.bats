#!/usr/bin/env bats
# fleet-assess: fleet_verdict is the whole decision the overseer and the sentinel probe act
# on, so it is pinned with numbers here rather than with a hot machine.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  # shellcheck source=/dev/null
  source "$REPO_ROOT/.local/bin/fleet-assess"
}

# v <load> <tctl> <mem%> <held> on a 24-core box -> the verdict word
v() { fleet_verdict "$1" 24 "$2" "$3" "$4" | cut -d' ' -f1; }

@test "the 2026-10-23 incident (load 96 on 24 cores) is HOLD" {
  run fleet_verdict 96 24 95.8 60 0
  assert_output --partial 'HOLD load 4.0x'
}

@test "load at exactly 1.75x cores is HOLD, just under is OK" {
  [ "$(v 42 80 60 0)" = HOLD ]
  [ "$(v 41.9 80 60 0)" = OK ]
}

@test "the 2026-10-26 miss (load 46.5 on 24 cores, top 0% idle) is HOLD" {
  [ "$(v 46.5 92.4 57 0)" = HOLD ]
}

@test "Tctl in the 90s at low load is OK (Zen 4 boosts to 95 by design)" {
  [ "$(v 5 93 60 0)" = OK ]
}

@test "Tctl at the throttle point with the box saturated is HOLD" {
  [ "$(v 36 95 60 0)" = HOLD ]
  [ "$(v 35.9 95 60 0)" = OK ]
}

@test "low memory alone is HOLD" {
  run fleet_verdict 5 24 60 8 0
  assert_output --partial 'HOLD memory 8%'
}

@test "between the marks: HOLD while held, OK when nothing is held" {
  [ "$(v 30 80 60 1)" = HOLD ]
  [ "$(v 30 80 60 0)" = OK ]
}

@test "under the low mark while held is CLEAR; with nothing held it is OK" {
  [ "$(v 23 80 60 1)" = CLEAR ]
  [ "$(v 23 80 60 0)" = OK ]
}

@test "CLEAR also needs memory back over the low mark" {
  [ "$(v 10 80 20 1)" = HOLD ]
}

@test "an unreadable Tctl does not trip anything" {
  [ "$(v 5 - 60 0)" = OK ]
}

@test "thresholds are data: FLEET_HOLD_LOAD_X moves the line" {
  FLEET_HOLD_LOAD_X=1 run fleet_verdict 30 24 60 60 0
  assert_output --partial 'HOLD'
}

@test "--watch-probe exits 1 on HOLD and 0 on OK" {
  FLEET_HOLD_LOAD_X=0 run "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_failure 1
  assert_output --partial 'HOLD'
  FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOT_TCTL=1000 \
    run "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
}

@test "only a machine-resource hold counts as held; a dispatch hold does not" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  mkdir -p "$AGENT_HOLD_DIR"
  HOLD_ROOT="$AGENT_HOLD_DIR"
  run holds_set
  assert_failure
  touch "$AGENT_HOLD_DIR/dispatch"
  run holds_set
  assert_failure
  touch "$AGENT_HOLD_DIR/unity"
  run holds_set
  assert_success
}

@test "--watch-probe between the marks: OK with only the dispatch hold, HOLD with a unity hold" {
  export AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  mkdir -p "$AGENT_HOLD_DIR"
  touch "$AGENT_HOLD_DIR/dispatch"
  local between="FLEET_HOLD_LOAD_X=1000 FLEET_HOLD_MEM_PCT=0 FLEET_HOT_TCTL=1000 FLEET_CLEAR_LOAD_X=0"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_success
  assert_output --partial 'OK'
  touch "$AGENT_HOLD_DIR/unity"
  run env $between "$REPO_ROOT/.local/bin/fleet-assess" --watch-probe
  assert_failure 1
  assert_output --partial 'HOLD held'
}
