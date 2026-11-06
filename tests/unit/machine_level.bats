#!/usr/bin/env bats
# lib/machine-mode.sh level_scale: the machine-mode level multiplies the start limits where they
# are read. What these pin: mid is the confs' own numbers exactly, as given; high and low give the
# levels file's numbers; a key the levels file does not name is never scaled; no level takes a
# nonzero limit to 0; a level the file does not list scales nothing and says so; and the real
# modes and levels files agree, so that guard never fires on the shipped data.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  LIB="$REPO_ROOT/.local/lib/machine-mode.sh"
  mkdir -p "$HOME/.agent"
}

# The conf's own values, and one the level must leave alone.
TODAY='DISPATCH_PER_PASS 3 DISPATCH_NIGHT_MAX 6 DISPATCH_MAX_LOAD 1.5 CLAUDE_ACCT_PACE_SLACK_PCT 5 CLAUDE_ACCT_RESERVE_PCT 15 DISPATCH_MAX_LIVE 40'

scale() { bash -c '. "$1"; shift; level_scale "$@"' _ "$LIB" "$@"; }
mode() { echo "MACHINE_MODE=$1" > "$HOME/.agent/machine-mode.env"; }

@test "with nothing set the level is mid and every value comes back as given" {
  # shellcheck disable=SC2086
  run scale $TODAY DISPATCH_MAX_LOAD 0.70
  assert_success
  assert_output "3 6 1.5 5 15 40 0.70"
  mode open
  # shellcheck disable=SC2086
  run scale $TODAY
  assert_output "3 6 1.5 5 15 40"
}

@test "full is high: twice the starts and night items, 2.1 load a core, 10 points of slack, 10 kept back" {
  mode full
  # shellcheck disable=SC2086
  run scale $TODAY
  assert_success
  assert_output "6 12 2.1 10 10 40"
}

@test "reserved is low, and no level takes a nonzero limit to 0" {
  mode reserved
  # shellcheck disable=SC2086
  run scale $TODAY DISPATCH_PER_PASS 1 CLAUDE_ACCT_PACE_SLACK_PCT 1 DISPATCH_MAX_LOAD 0.01 DISPATCH_PER_PASS 0
  assert_success
  assert_output "1 3 0.9 1 20 40 1 1 0.01 0"
}

@test "a level the levels file does not list scales nothing and says so" {
  printf 'odd|2|2|1|as-today|turbo\n' > "$BATS_TEST_TMPDIR/modes"
  export MACHINE_MODE_MODES="$BATS_TEST_TMPDIR/modes"
  run --separate-stderr scale DISPATCH_PER_PASS 3
  assert_success
  assert_output 3
  [[ "$stderr" == *'level turbo is not in'* ]] || fail "$stderr"
}

@test "a mode row with no level column is mid" {
  printf 'old|2|2|1|as-today\n' > "$BATS_TEST_TMPDIR/modes"
  export MACHINE_MODE_MODES="$BATS_TEST_TMPDIR/modes"
  run bash -c '. "$1"; machine_level' _ "$LIB"
  assert_output mid
}

@test "every mode in the real modes file names a level the real levels file lists, and mid is all 1" {
  local levels
  levels="$(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.config/machine-mode/levels" | tail -n +2 | cut -d'|' -f1)"
  while IFS='|' read -r m _ _ _ _ l; do
    grep -qx "$l" <<< "$levels" || fail "mode $m names level '$l', not in levels"
  done < <(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.config/machine-mode/modes")
  run awk -F'|' '$1 == "mid" { for (i = 2; i <= NF; i++) if ($i != 1) bad = 1; found = 1 } END { exit !(found && !bad) }' \
    "$REPO_ROOT/.config/machine-mode/levels"
  assert_success
  # The default, the last row, stays mid: nothing set must be today's numbers.
  assert_equal "$(grep -Ev '^[[:space:]]*(#|$)' "$REPO_ROOT/.config/machine-mode/modes" | tail -1 | cut -d'|' -f6)" mid
}
