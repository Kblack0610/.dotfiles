#!/usr/bin/env bats
# machine-mode: the one switch for how much of this workstation background work may use. What
# these pin: each mode writes its level to the state file and nothing else, on any machine;
# machine-mode never sets or lifts a dispatch hold, only reports one. The
# clock: the real hours file covers the day once and names real modes; a new part's mode applies
# once; a hand mode holds inside its part, and past a boundary while the human is here; a quiet
# tick exits 0, a held hand mode 75, a state file it cannot write 1 and an unreadable hours file 2
# (the unit's result, and which it retries); machine-clock.timer fires at the start of each part of
# the shipped hours file and is enabled.
# agent-hold is the real one against a sandbox hold dir, so its list format is pinned too.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MM="$REPO_ROOT/.local/bin/machine-mode"
  STATE="$HOME/.agent/machine-mode.env"
  export FX="$BATS_TEST_TMPDIR" AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  ln -s "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  # Never a real waybar: the switch goes through desk, which signals it by process name.
  mkdir -p "$HOME/.local/bin" && ln -s "$REPO_ROOT/.local/bin/desk" "$HOME/.local/bin/desk"
  # The default bar is noctalia; record waybar so the signal goes to the pkill stub.
  mkdir -p "$HOME/.local/state/desk" && echo "bar=waybar-classic" > "$HOME/.local/state/desk/parts"
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/pkill.log"\n' > "$SANDBOX/bin/pkill"
  # A switch reaches no cluster and no Prometheus: either call fails the test.
  for t in kubectl curl; do printf '#!/usr/bin/env bash\necho "%s $*" >> "$FX/remote.log"; exit 1\n' "$t" > "$SANDBOX/bin/$t"; done
  printf '#!/usr/bin/env bash\necho "${PRESENCE:-here 0 tmux}"\n' > "$SANDBOX/bin/fleet-presence"
  chmod +x "$SANDBOX/bin/pkill" "$SANDBOX/bin/kubectl" "$SANDBOX/bin/curl" "$SANDBOX/bin/fleet-presence"
}

teardown() { [ ! -e "$FX/remote.log" ] || { cat "$FX/remote.log"; return 1; }; }

state() { sed -n "s/^$1=//p" "$STATE"; }

@test "with nothing set the mode is the last row, as today" {
  run "$MM"
  assert_success
  assert_line "mode: open"
  assert_line "level: mid"
  assert_line "new agent sessions: as today"
}

@test "reserved sets the low level, signals the chip, and leaves dispatch running" {
  run "$MM" reserved
  assert_success
  assert_line "mode: reserved"
  assert_line "level: low"
  assert_line "new agent sessions: as today"
  [ ! -e "$AGENT_HOLD_DIR/dispatch" ]
  assert_equal "$(state MACHINE_MODE) $(state MODE_BY)" "reserved hand"
  run cat "$FX/pkill.log"
  assert_output "-RTMIN+10 -x waybar"
}

@test "full is the high level, the state file holds no level copy, and one click from it is reserved" {
  run "$MM" full
  assert_success
  assert_line "mode: full"
  assert_line "level: high"
  # The level is the mode row's, never a second copy in the state file.
  run grep -cE 'LEVEL|RUNNERS|UNITY' "$STATE"
  assert_output 0
  run "$MM" next
  assert_line "mode: reserved"
  assert_line "level: low"
}

@test "next walks the file order and wraps" {
  run "$MM" next
  assert_line "mode: full"
  run "$MM" next
  assert_line "mode: reserved"
  run "$MM" next
  assert_line "mode: shared"
  run "$MM" next
  assert_line "mode: open"
}


@test "another session's dispatch hold is neither replaced nor released" {
  agent-hold set dispatch --by binks "load" >/dev/null
  run "$MM" reserved
  assert_success
  assert_line "new agent sessions: paused by binks"
  run "$MM" open
  assert_success
  assert_line "new agent sessions: paused by binks"
  run grep -x 'by: binks' "$AGENT_HOLD_DIR/dispatch"
  assert_success
}


@test "an unknown mode changes nothing, and a regex is not a mode" {
  run "$MM" turbo
  assert_failure
  assert_output --partial "no mode 'turbo' (modes: full reserved shared open)"
  run "$MM" '.*'
  assert_failure
  [ ! -e "$STATE" ]
}

@test "a state file naming a dropped mode falls back to the last row" {
  mkdir -p "$HOME/.agent"
  echo 'MACHINE_MODE=gone' > "$STATE"
  run "$MM"
  assert_line "mode: open"
}

hours_fixture() {
  export MACHINE_MODE_HOURS="$FX/hours"
  printf '# test\nday|07:00-23:00|shared|you\nnight|23:00-07:00|full|builds\n' > "$MACHINE_MODE_HOURS"
}

@test "the shipped hours cover every minute of the day exactly once, each with a listed mode" {
  run bash -c '. "$1"
    for h in $(seq 0 23); do for m in $(seq 0 59); do
      t=$(printf "%02d:%02d" "$h" "$m") n=0
      while IFS="|" read -r _ w mode _; do
        mode_row "$mode" >/dev/null || { echo "unknown mode $mode"; exit 1; }
        hhmm_in "$t" "$w" && n=$((n + 1))
      done < <(hour_rows)
      [ "$n" = 1 ] || { echo "$t is in $n parts"; exit 1; }
    done; done' _ "$REPO_ROOT/.local/lib/machine-mode.sh"
  assert_success
}

@test "hours lists each part and marks the one now" {
  hours_fixture
  MACHINE_MODE_NOW=02:00 run "$MM" hours
  assert_success
  assert_line --regexp '^day +07:00-23:00 +shared +you$'
  assert_line --regexp '^night +23:00-07:00 +full +builds  <- now$'
}

@test "the clock applies a new part's mode once, and the status says who set it" {
  hours_fixture
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_success
  assert_line "mode: shared"
  assert_equal "$(state MODE_BY) $(state CLOCK_PART)" "clock day"
  MACHINE_MODE_NOW=12:15 run "$MM" clock
  assert_success
  assert_output ""
  MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_line "mode: full"
  assert_line "clock: night (23:00-07:00) runs full; this mode was set by the clock"
}

@test "a hand mode stands inside its part, holds past a boundary while the human is here, and yields once away" {
  hours_fixture
  MACHINE_MODE_NOW=12:00 "$MM" clock >/dev/null
  MACHINE_MODE_NOW=22:30 run "$MM" reserved
  assert_line "clock: day (07:00-23:00) runs shared; this mode was set by hand"
  MACHINE_MODE_NOW=22:45 run "$MM" clock
  assert_output ""
  MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_failure 75   # the unit retries a held tick every 15 minutes
  assert_output --partial "reserved was set by hand and you are here"
  assert_equal "$(state MACHINE_MODE)" reserved
  PRESENCE="away 40 tmux" MACHINE_MODE_NOW=23:30 run "$MM" clock
  assert_line "mode: full"
  assert_equal "$(state MODE_BY)" clock
}

@test "auto hands the mode back to the clock now, whoever is here" {
  hours_fixture
  MACHINE_MODE_NOW=12:00 "$MM" reserved >/dev/null
  MACHINE_MODE_NOW=12:00 run "$MM" auto
  assert_success
  assert_line "mode: shared"
  assert_equal "$(state MODE_BY) $(state CLOCK_PART)" "clock day"
}

@test "an hours row naming a mode the modes file lacks stops the clock and changes nothing" {
  export MACHINE_MODE_HOURS="$FX/hours"
  printf 'all|00:00-24:00|turbo|x\n' > "$MACHINE_MODE_HOURS"
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_failure
  assert_output --partial "names mode 'turbo'"
  [ ! -e "$STATE" ]
}

@test "an old state file with no setter counts as by hand" {
  hours_fixture
  mkdir -p "$HOME/.agent"
  printf 'MACHINE_MODE=reserved\n' > "$STATE"
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_failure 75
  assert_output --partial "reserved was set by hand and you are here"
  assert_equal "$(state MACHINE_MODE)" reserved
}

@test "machine-clock.timer fires at the start of each part of the shipped hours file, and is enabled" {
  U="$REPO_ROOT/.config/systemd/user"
  want="$(grep -v '^#' "$REPO_ROOT/.config/machine-mode/hours" | grep . | cut -d'|' -f2 | cut -d- -f1 | sort)"
  got="$(sed -n 's/^OnCalendar=\*-\*-\* \([0-9:]*\):00$/\1/p' "$U/machine-clock.timer" | sort)"
  assert_equal "$got" "$want"
  grep -q '^Persistent=true' "$U/machine-clock.timer"
  grep -q '^ExecStart=%h/.local/bin/machine-mode clock$' "$U/machine-clock.service"
  [ -L "$U/timers.target.wants/machine-clock.timer" ]
}


@test "a tick that changes nothing exits 0 and says nothing; one that cannot write the state file exits 1" {
  hours_fixture
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_success
  MACHINE_MODE_NOW=12:15 run "$MM" clock
  assert_success
  assert_output ""
  export MACHINE_MODE_STATE="$FX/not-a-dir/machine-mode.env"
  : > "$FX/not-a-dir"
  MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_failure 1
  assert_output --partial "could not write"
}

@test "an unreadable hours file exits 2, the one status machine-clock.service does not retry" {
  export MACHINE_MODE_HOURS="$FX/hours"
  printf 'all|00:00-24:00|turbo|x\n' > "$MACHINE_MODE_HOURS"
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_failure 2
  grep -q '^RestartPreventExitStatus=2$' "$REPO_ROOT/.config/systemd/user/machine-clock.service"
  grep -q '^Restart=on-failure$' "$REPO_ROOT/.config/systemd/user/machine-clock.service"
}

@test "machine-clock.service and .timer pass systemd-analyze verify" {
  command -v systemd-analyze >/dev/null || skip "no systemd-analyze"
  # %h is the sandbox home here, which holds no machine-mode, so that one finding is not the unit's fault.
  run bash -c 'systemd-analyze verify --user "$@" 2>&1 | grep -v "is not executable"' _ \
    "$REPO_ROOT/.config/systemd/user/machine-clock.service" "$REPO_ROOT/.config/systemd/user/machine-clock.timer"
  assert_output ""
}

