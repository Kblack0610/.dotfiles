#!/usr/bin/env bats
# machine-mode: the one switch for how much of this workstation background work may use. What
# these pin: each mode writes its numbers to all three parts; the ConfigMap keeps other hosts'
# keys and a power override on this host; a dispatch hold is only ever machine-mode's own to
# change; an unreachable cluster applies the local parts, exits 1 and says so; a machine with no
# pool runners refuses; the status reads what the runners actually do, not what was asked. The
# clock: the real hours file covers the day once and names real modes; a new part's mode applies
# once; a hand mode holds inside its part, and past a boundary while the human is here; each
# tick reports its agentctl outcome, so a quiet tick is NOOP and never STALLED.
# agent-hold is the real one against a sandbox hold dir, so its list format is pinned too.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MM="$REPO_ROOT/.local/bin/machine-mode"
  HOST="$(uname -n)"
  STATE="$HOME/.agent/machine-mode.env"
  export FX="$BATS_TEST_TMPDIR" AGENT_HOLD_DIR="$BATS_TEST_TMPDIR/holds"
  export CC_PROM_URL=http://prom.test CC_KUBE_CONTEXT=test-ctx
  touch "$FX/actions.runner.host-unity-pool-1.service"
  export MACHINE_MODE_RUNNER_UNITS="$FX/actions.runner.*-unity-pool-*.service"
  ln -s "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  # Never a real waybar: the switch signals it by process name.
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/pkill.log"\n' > "$SANDBOX/bin/pkill"
  cat > "$SANDBOX/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/kubectl.log"
[ -n "${KUBE_FAIL:-}" ] && { echo "connection refused" >&2; exit 1; }
case " $* " in
  *" get "*) cat "$FX/cm.json" 2>/dev/null || true ;;  # --ignore-not-found: empty and 0
  *" apply "*) cat > "$FX/applied.json" ;;
esac
STUB
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  printf '#!/usr/bin/env bash\necho "${PRESENCE:-here 0 tmux}"\n' > "$SANDBOX/bin/fleet-presence"
  chmod +x "$SANDBOX/bin/pkill" "$SANDBOX/bin/kubectl" "$SANDBOX/bin/curl" "$SANDBOX/bin/fleet-presence"
  prom 2 2
}

# prom <admitted> <registered>: Prometheus's answer for this host.
prom() {
  jq -n --arg h "$HOST" --arg a "$1" --arg r "$2" '{status: "success", data: {result: [
    {metric: {__name__: "ci_governor_admitted", host: $h}, value: [0, $a]},
    {metric: {__name__: "ci_governor_registered", host: $h}, value: [0, $r]}]}}' > "$FX/prom.json"
}

pin() { jq -r --arg h "$HOST" '.data[$h]' "$FX/applied.json"; }
state() { sed -n "s/^$1=//p" "$STATE"; }

@test "with nothing set the mode is the last row and the numbers are today's" {
  run "$MM"
  assert_success
  assert_line "mode: open"
  assert_line "level: mid"
  assert_line "runners: 2 of 2 taking new jobs"
  assert_line "local Unity runs: 2, plus 1 when there is room"
  assert_line "new agent sessions: as today"
}

@test "reserved pins 0 slots, one Unity run, and holds dispatch as machine-mode" {
  run "$MM" reserved
  assert_success
  assert_line "mode: reserved"
  assert_line "runners: 2 of 2 taking new jobs, moving to 0"
  assert_line "new agent sessions: paused"
  assert_equal "$(pin)" '{"slots":0}'
  assert_equal "$(state UNITY_SLOTS)" 1
  assert_equal "$(state UNITY_BURST_SLOTS)" 0
  assert_equal "$(state RUNNERS_PINNED)" yes
  run grep -x 'by: machine-mode' "$AGENT_HOLD_DIR/dispatch"
  assert_success
  run grep -q 'context test-ctx' "$FX/kubectl.log"
  assert_success
  run cat "$FX/pkill.log"
  assert_output "-RTMIN+10 waybar"
}

@test "leaving reserved releases its hold and restores the numbers" {
  "$MM" reserved
  run "$MM" shared
  assert_success
  assert_equal "$(pin)" '{"slots":1}'
  assert_equal "$(state UNITY_SLOTS)" 2
  assert_equal "$(state UNITY_BURST_SLOTS)" 0
  [ ! -e "$AGENT_HOLD_DIR/dispatch" ]
  "$MM" open
  assert_equal "$(pin)" '{"slots":2}'
  assert_equal "$(state UNITY_BURST_SLOTS)" 1
}

@test "full is open's numbers at the high level, and one click from it is reserved" {
  run "$MM" full
  assert_success
  assert_line "mode: full"
  assert_line "level: high"
  assert_line "new agent sessions: as today"
  assert_equal "$(pin)" '{"slots":2}'
  assert_equal "$(state UNITY_SLOTS)" 2
  assert_equal "$(state UNITY_BURST_SLOTS)" 1
  # The level is the mode row's, never a second copy in the state file.
  run grep -c LEVEL "$STATE"
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

@test "the ConfigMap keeps other hosts and a power override on this host" {
  jq -n --arg h "$HOST" '{data: {"aws-burst-1": "{\"action\":\"on\",\"until\":9}", ($h): "{\"action\":\"off\",\"until\":5}"}}' > "$FX/cm.json"
  run "$MM" reserved
  assert_success
  assert_equal "$(jq -r '.data["aws-burst-1"]' "$FX/applied.json")" '{"action":"on","until":9}'
  assert_equal "$(pin)" '{"action":"off","until":5,"slots":0}'
  assert_equal "$(jq -r '.metadata.namespace + "/" + .metadata.name' "$FX/applied.json")" monitoring/ci-runner-governor-override
}

@test "a ConfigMap that does not exist yet is created, and a bad value for this host is replaced" {
  "$MM" shared
  assert_equal "$(jq -r '.kind' "$FX/applied.json")" ConfigMap
  jq -n --arg h "$HOST" '{data: {($h): "not json"}}' > "$FX/cm.json"
  "$MM" reserved
  assert_equal "$(pin)" '{"slots":0}'
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

@test "a reserved hold lifted by someone else is reported, not silently re-read as paused" {
  "$MM" reserved
  agent-hold release dispatch >/dev/null
  run "$MM"
  assert_line "new agent sessions: as today, the hold was lifted: run machine-mode reserved to pause again"
}

@test "an unreachable cluster applies the local parts, exits 1 and names what changed" {
  KUBE_FAIL=1 run "$MM" reserved
  assert_failure
  assert_output --partial "the runners did not change"
  assert_output --partial "0 was not applied: run machine-mode reserved again"
  assert_equal "$(state MACHINE_MODE)" reserved
  assert_equal "$(state RUNNERS_PINNED)" no
  [ -e "$AGENT_HOLD_DIR/dispatch" ]
  run "$MM" reserved
  assert_success
  assert_equal "$(state RUNNERS_PINNED)" yes
}

@test "no kube context is the same failure, with no kubectl call on a blank context" {
  unset CC_KUBE_CONTEXT
  run "$MM" shared
  assert_failure
  assert_output --partial "CC_KUBE_CONTEXT is not set"
  [ ! -e "$FX/kubectl.log" ]
}

@test "the status reads the runners as they are, and says when it cannot" {
  "$MM" reserved
  prom 1 2
  run "$MM"
  assert_line "runners: 1 of 2 taking new jobs, moving to 0"
  prom 0 2
  run "$MM"
  assert_line "runners: 0 of 2 taking new jobs"
  CURL_FAIL=1 run "$MM"
  assert_success
  assert_line "runners: ? of ? taking new jobs (cannot read Prometheus), set to 0"
}

@test "a mode above what is registered does not read as moving" {
  prom 1 1
  run "$MM"
  assert_line "runners: 1 of 1 taking new jobs"
}

@test "an unknown mode changes nothing, and a regex is not a mode" {
  run "$MM" turbo
  assert_failure
  assert_output --partial "no mode 'turbo' (modes: full reserved shared open)"
  run "$MM" '.*'
  assert_failure
  [ ! -e "$STATE" ]
  [ ! -e "$FX/kubectl.log" ]
}

@test "a state file naming a dropped mode falls back to the last row" {
  mkdir -p "$HOME/.agent"
  echo 'MACHINE_MODE=gone' > "$STATE"
  run "$MM"
  assert_line "mode: open"
}

@test "a machine with no pool runners refuses and writes nothing" {
  export MACHINE_MODE_RUNNER_UNITS="$FX/none-*.service"
  run "$MM" reserved
  assert_failure
  assert_output --partial "no pool runners on this machine"
  [ ! -e "$STATE" ]
  [ ! -e "$AGENT_HOLD_DIR/dispatch" ]
  [ ! -e "$FX/kubectl.log" ]
}

# hours_fixture: a day of two parts, so the clock tests do not move with the shipped hours.
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
    done; done
    clock_window night' _ "$REPO_ROOT/.local/lib/machine-mode.sh"
  assert_success
  assert_output --regexp '^[0-9]{2}:[0-9]{2}-[0-9]{2}:[0-9]{2}$'
}

@test "hours lists each part and marks the one now, on a machine with no runners too" {
  hours_fixture
  export MACHINE_MODE_RUNNER_UNITS="$FX/none-*.service"
  MACHINE_MODE_NOW=02:00 run "$MM" hours
  assert_success
  assert_line --regexp '^day +07:00-23:00 +shared +you$'
  assert_line --regexp '^night +23:00-07:00 +full +builds  <- now$'
  run "$MM" clock
  assert_success
  assert_output ""
}

@test "the clock applies a new part's mode once, and the status says who set it" {
  hours_fixture
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_success
  assert_line "mode: shared"
  assert_equal "$(state MODE_BY) $(state CLOCK_PART)" "clock day"
  : > "$FX/kubectl.log"
  MACHINE_MODE_NOW=12:15 run "$MM" clock
  assert_success
  assert_output ""
  [ ! -s "$FX/kubectl.log" ]
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
  assert_success
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

@test "a pin that failed at a part's start is retried on the next tick, and an old state file counts as by hand" {
  hours_fixture
  KUBE_FAIL=1 MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_failure
  assert_equal "$(state RUNNERS_PINNED) $(state CLOCK_PART)" "no night"
  MACHINE_MODE_NOW=23:15 run "$MM" clock
  assert_success
  assert_equal "$(state RUNNERS_PINNED)" yes
  printf 'MACHINE_MODE=reserved\nUNITY_SLOTS=1\nUNITY_BURST_SLOTS=0\nRUNNERS_PINNED=yes\n' > "$STATE"
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_output --partial "reserved was set by hand and you are here"
  assert_equal "$(state MACHINE_MODE)" reserved
}

@test "each tick reports its outcome to the machine-clock runner: WORKED, NOOP, FAILED" {
  hours_fixture
  out() { cat "$HOME/.local/state/agentctl/machine-clock/last-outcome"; }
  MACHINE_MODE_NOW=12:00 "$MM" clock >/dev/null
  assert_equal "$(out)" WORKED
  MACHINE_MODE_NOW=12:15 "$MM" clock >/dev/null
  assert_equal "$(out)" NOOP
  MACHINE_MODE_NOW=12:30 "$MM" reserved >/dev/null
  MACHINE_MODE_NOW=23:00 "$MM" clock >/dev/null
  assert_equal "$(out)" NOOP
  MACHINE_MODE_NOW=12:00 "$MM" auto >/dev/null
  KUBE_FAIL=1 MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_failure
  assert_equal "$(out)" FAILED
}

# The release lane: `release-lane` writes only "<host>.reserve" {"until": <epoch>}, which the governor
# reads as a pin to 0 until then (home-config governor.py read_pins).
reservation() { jq -r --arg k "$1.reserve" '.data[$k] | fromjson | .until' "$FX/applied.json"; }

@test "release-lane writes the host's own reserve key with its end, and keeps every other key" {
  jq -n --arg h "$HOST" '{data: {"razer-laptop": "{\"slots\":1,\"action\":\"off\",\"until\":5}", ($h): "{\"slots\":2}"}}' > "$FX/cm.json"
  before="$(date +%s)"
  run "$MM" release-lane razer-laptop --until "6 hours"
  assert_success
  assert_output --partial "razer-laptop: reserved for release jobs until"
  until="$(reservation razer-laptop)"
  ((until >= before + 21600 && until <= before + 21610))
  assert_equal "$(jq -r '.data["razer-laptop"]' "$FX/applied.json")" '{"slots":1,"action":"off","until":5}'
  assert_equal "$(pin)" '{"slots":2}'
  [ ! -e "$STATE" ]
}

@test "release-lane works on a machine with no pool runners, since it pins another host" {
  export MACHINE_MODE_RUNNER_UNITS="$FX/none-*.service"
  run "$MM" release-lane razer-laptop --until "2 hours"
  assert_success
  [ -n "$(reservation razer-laptop)" ]
}

@test "release-lane refuses a past, unreadable or over-a-day end, and a missing --until, writing nothing" {
  for args in "razer-laptop --until yesterday" "razer-laptop --until notatime" "razer-laptop --until 30hours" \
      "razer-laptop" "razer-laptop --until"; do
    # shellcheck disable=SC2086
    run "$MM" release-lane $args
    assert_failure
  done
  run "$MM" release-lane razer-laptop --until "2 days"
  assert_failure
  assert_output --partial "more than 24h ahead"
  [ ! -e "$FX/applied.json" ]
}

@test "clear ends the reservation now, and the list marks it ended" {
  "$MM" release-lane razer-laptop --until "3 hours"
  cp "$FX/applied.json" "$FX/cm.json"
  run "$MM" release-lane
  assert_success
  assert_output --regexp '^razer-laptop: until [0-9T:-]+Z$'
  run "$MM" release-lane --clear razer-laptop
  assert_success
  ((  $(reservation razer-laptop) <= $(date +%s) ))
  cp "$FX/applied.json" "$FX/cm.json"
  run "$MM" release-lane
  assert_output --partial ", ended"
}

@test "an unreachable cluster or no kube context fails the reservation" {
  KUBE_FAIL=1 run "$MM" release-lane razer-laptop --until "2 hours"
  assert_failure
  CC_KUBE_CONTEXT= run "$MM" release-lane razer-laptop --until "2 hours"
  assert_failure
  assert_output --partial "CC_KUBE_CONTEXT is not set"
}
