#!/usr/bin/env bats
# machine-mode: the one switch for how much of this workstation background work may use. What
# these pin: each mode writes its level to the state file and its runner count to the ConfigMap; each write is a merge-patch of
# its own key alone, and every key passes the governor's override schema; machine-mode never sets or lifts a dispatch hold,
# only reports one; an unreachable cluster applies the local part, exits 1 and says so; a machine with no
# pool runners refuses; the status reads what the runners do and where the governor moves them
# (ci_governor_effective_slots), not what was asked. The
# clock: the real hours file covers the day once and names real modes; a new part's mode applies
# once; a hand mode holds inside its part, and past a boundary while the human is here; a quiet
# tick exits 0, a held hand mode 75, a failed pin 1 and an unreadable hours file 2 (the unit's
# result, and which it retries); machine-clock.timer fires at the start of each part of the shipped
# hours file and is enabled.
# agent-hold is the real one against a sandbox hold dir, so its list format is pinned too.

# The governor whose override.schema.json each write is checked against; the test skips without it.
GOVERNOR_PY="${GOVERNOR_PY:-$HOME/dev/home/home-config/apps/ci-runner-governor/governor.py}"

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
  # No count directory: the slot part is skipped until a test makes one (slots_fixture).
  export MACHINE_MODE_SLOT_FILE="$FX/ci-slots/slots"
  ln -s "$REPO_ROOT/.local/bin/agent-hold" "$SANDBOX/bin/agent-hold"
  # Never a real waybar: the switch goes through desk, which signals it by process name.
  mkdir -p "$HOME/.local/bin" && ln -s "$REPO_ROOT/.local/bin/desk" "$HOME/.local/bin/desk"
  printf '#!/usr/bin/env bash\necho "$*" >> "$FX/pkill.log"\n' > "$SANDBOX/bin/pkill"
  # The ConfigMap is cm.json. A merge-patch applies to it (a null removes the key) and fails
  # NotFound with none; create refuses one that exists; any other write fails, so a
  # get-then-apply of the whole object cannot pass.
  cat > "$SANDBOX/bin/kubectl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/kubectl.log"
[ -n "${KUBE_FAIL:-}" ] && { echo "connection refused" >&2; exit 1; }
verb="" patch="" lit=""
while [ $# -gt 0 ]; do
  case "$1" in
    get|patch|create|apply|replace|edit) [ -n "$verb" ] || verb="$1" ;;
    -p) patch="$2"; shift ;;
    --from-literal=*) lit="${1#--from-literal=}" ;;
  esac
  shift
done
case "$verb" in
  get) cat "$FX/cm.json" 2>/dev/null || true ;;  # --ignore-not-found: empty and 0
  patch)
    [ -e "$FX/cm.json" ] || { echo 'Error from server (NotFound): configmaps "ci-runner-governor-override" not found' >&2; exit 1; }
    echo "$patch" >> "$FX/patches.log"
    jq --argjson p "$patch" '.data = ((.data // {}) + $p.data | with_entries(select(.value != null)))' "$FX/cm.json" > "$FX/cm.new"
    mv "$FX/cm.new" "$FX/cm.json" ;;
  create)
    [ -e "$FX/cm.json" ] && { echo 'Error from server (AlreadyExists)' >&2; exit 1; }
    jq -n --arg k "${lit%%=*}" --arg v "${lit#*=}" '{data: {($k): $v}}' > "$FX/cm.json" ;;
  *) echo "kubectl $verb: machine-mode writes only by merge-patch" >&2; exit 1 ;;
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

# prom <admitted> <registered> [<effective> [<source>]]: Prometheus's answer for this host;
# effective is where the governor moves it (default: what it admits, source governor).
prom() {
  jq -n --arg h "$HOST" --arg a "$1" --arg r "$2" --arg e "${3:-$1}" --arg s "${4:-governor}" '{status: "success", data: {result: [
    {metric: {__name__: "ci_governor_admitted", host: $h}, value: [0, $a]},
    {metric: {__name__: "ci_governor_registered", host: $h}, value: [0, $r]},
    {metric: {__name__: "ci_governor_effective_slots", host: $h, source: $s}, value: [0, $e]}]}}' > "$FX/prom.json"
}

pin() { jq -r --arg k "$HOST.slots" '.data[$k]' "$FX/cm.json"; }
state() { sed -n "s/^$1=//p" "$STATE"; }

@test "with nothing set the mode is the last row, as today" {
  prom 0 2
  run "$MM"
  assert_success
  assert_line "mode: open"
  assert_line "level: mid"
  assert_line "runners: 0 of 2 taking new jobs"
  assert_line "new agent sessions: as today"
}

@test "reserved pins 0 slots and the low level, and leaves dispatch running" {
  prom 2 2 0 slots
  run "$MM" reserved
  assert_success
  assert_line "mode: reserved"
  assert_line "runners: 2 of 2 taking new jobs, moving to 0"
  assert_line "level: low"
  assert_line "new agent sessions: as today"
  [ ! -e "$AGENT_HOLD_DIR/dispatch" ]
  assert_equal "$(pin)" '{"slots":0,"local":1,"by":"machine-mode reserved"}'
  assert_equal "$(state RUNNERS_PINNED)" yes
  run grep -q 'context test-ctx' "$FX/kubectl.log"
  assert_success
  run cat "$FX/pkill.log"
  assert_output "-RTMIN+10 -x waybar"
}

@test "leaving reserved restores the pin" {
  "$MM" reserved
  run "$MM" shared
  assert_success
  assert_equal "$(pin)" '{"slots":0,"local":2,"by":"machine-mode shared"}'
  [ ! -e "$AGENT_HOLD_DIR/dispatch" ]
  "$MM" open
  assert_equal "$(pin)" '{"slots":0,"local":2,"by":"machine-mode open"}'
}

@test "full takes no runner here, at the high level, and one click from it is reserved" {
  run "$MM" full
  assert_success
  assert_line "mode: full"
  assert_line "level: high"
  assert_line "new agent sessions: as today"
  assert_equal "$(pin)" '{"slots":0,"local":2,"by":"machine-mode full"}'
  # The local seat pin goes to the governor's key, never to the state file.
  run grep -c UNITY "$STATE"
  assert_output 0
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

@test "a pin patches only this host's slots key, so every other key stands" {
  jq -n --arg h "$HOST" '{data: {"aws-burst-1.power": "{\"action\":\"on\",\"until\":9}",
    ($h + ".power"): "{\"action\":\"off\",\"until\":5}", "lane-host.reserve": "{\"until\":7}"}}' > "$FX/cm.json"
  run "$MM" reserved
  assert_success
  assert_equal "$(jq -c '.data | del(.[$k])' --arg k "$HOST.slots" "$FX/cm.json")" \
    "$(jq -nc --arg h "$HOST" '{"aws-burst-1.power": "{\"action\":\"on\",\"until\":9}",
      ($h + ".power"): "{\"action\":\"off\",\"until\":5}", "lane-host.reserve": "{\"until\":7}"}')"
  assert_equal "$(jq -c '.data | keys' "$FX/patches.log")" "$(jq -nc --arg k "$HOST.slots" '[$k]')"
  run grep -E ' (get|apply) ' "$FX/kubectl.log"
  assert_failure
}

@test "a ConfigMap that does not exist yet is created, and a bad value for this host is replaced" {
  "$MM" shared
  assert_equal "$(pin)" '{"slots":0,"local":2,"by":"machine-mode shared"}'
  run grep -c ' create configmap ' "$FX/kubectl.log"
  assert_output 1
  jq --arg k "$HOST.slots" '.data[$k] = "not json"' "$FX/cm.json" > "$FX/cm.new" && mv "$FX/cm.new" "$FX/cm.json"
  "$MM" reserved
  assert_equal "$(pin)" '{"slots":0,"local":1,"by":"machine-mode reserved"}'
}

@test "every key machine-mode writes passes the governor's override schema" {
  # A known-good key of the newest shape probes the governor, so an older one skips rather than
  # passes or fails: one without check-override, or one before the slots key took local (hc-726 p6).
  python3 "$GOVERNOR_PY" check-override h.slots '{"slots":0,"local":1,"by":"x"}' 2>/dev/null \
    || skip "no governor whose check-override takes local at $GOVERNOR_PY (set GOVERNOR_PY)"
  lane_prom lane-host "$HOST"
  for mode in full reserved shared open; do "$MM" "$mode" >/dev/null; done
  "$MM" release-lane lane-host --until "2 hours" >/dev/null
  [ "$(jq '.data | length' "$FX/cm.json")" = 2 ]
  while IFS=$'\t' read -r key value; do
    run python3 "$GOVERNOR_PY" check-override "$key" "$value"
    assert_success
  done < <(jq -r '.data | to_entries[] | [.key, .value] | @tsv' "$FX/cm.json")
  # The check bites: the shape before hc-651 fails it.
  run python3 "$GOVERNOR_PY" check-override "$HOST" '{"slots":0}'
  assert_failure
  assert_output --partial "override $HOST: '$HOST' does not match"
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

@test "an unreachable cluster applies the local part, exits 1 and names what changed" {
  KUBE_FAIL=1 run "$MM" reserved
  assert_failure
  assert_output --partial "the runners and local Unity runs did not change"
  assert_output --partial "0 was not applied: run machine-mode reserved again"
  assert_equal "$(state MACHINE_MODE)" reserved
  assert_equal "$(state RUNNERS_PINNED)" no
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

@test "the status reads the runners as they are and where the governor moves them, and says when it cannot" {
  "$MM" reserved
  prom 1 2 0 slots
  run "$MM"
  assert_line "runners: 1 of 2 taking new jobs, moving to 0"
  prom 2 2 0 reserve
  run "$MM"
  assert_line "runners: 2 of 2 taking new jobs, moving to 0 (reserved for release jobs)"
  prom 0 2 0 slots
  run "$MM"
  assert_line "runners: 0 of 2 taking new jobs"
  CURL_FAIL=1 run "$MM"
  assert_success
  assert_line "runners: ? of ? taking new jobs (cannot read Prometheus), set to 0"
}

@test "the target is the governor's, not the mode's number" {
  "$MM" full
  prom 0 0 0 slots
  run "$MM"
  assert_line "runners: 0 of 0 taking new jobs"
  # A FULL host the governor keeps below its pin reads as not moving.
  prom 0 2 0 governor
  run "$MM"
  assert_line "runners: 0 of 2 taking new jobs"
  # A governor that reports no target says so, never a target of its own.
  jq 'del(.data.result[2])' "$FX/prom.json" > "$FX/prom.new" && mv "$FX/prom.new" "$FX/prom.json"
  run "$MM"
  assert_line "runners: 0 of 2 taking new jobs (the governor reports no target), set to 1"
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

# slots_fixture: two slots, both running, a count directory, and stubs for the units. systemctl
# keeps a unit's state as a file under active/ (a user unit's as user.<name>), and answers show with
# the slot's home; pgrep matches procs, the command lines running; systemd-run logs and runs its
# command now, or leaves its unit active with WAITER_HOLD. The job-end waiter logs and exits WAIT_RC.
slots_fixture() {
  touch "$FX/actions.runner.host-unity-pool-2.service"
  mkdir -p "$FX/ci-slots" "$FX/active"
  touch "$FX/active/actions.runner.host-unity-pool-1.service" "$FX/active/actions.runner.host-unity-pool-2.service"
  : > "$FX/procs"
  cat > "$SANDBOX/bin/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/systemctl.log"
user=""; [ "$1" = --user ] && { user=user.; shift; }
[ "$1" = --no-ask-password ] && shift
unit="${*: -1}"
case "$1" in
  is-active) [ -e "$FX/active/$user$unit" ] ;;
  show) echo "$FX/home/$unit" ;;
  start) [ -z "$user" ] && [ -n "${SYSTEMCTL_FAIL:-}" ] && exit 1; touch "$FX/active/$user$unit" ;;
  stop) [ -z "$user" ] && [ -n "${SYSTEMCTL_FAIL:-}" ] && exit 1; rm -f "$FX/active/$user$unit" ;;
esac
STUB
  printf '#!/usr/bin/env bash
grep -qE -- "${*: -1}" "$FX/procs"
' > "$SANDBOX/bin/pgrep"
  cat > "$SANDBOX/bin/systemd-run" <<'STUB'
#!/usr/bin/env bash
echo "$*" >> "$FX/systemd-run.log"
while [ "$1" != /bin/sh ]; do [ "$1" = --unit ] && unit="$2"; shift; done
touch "$FX/active/user.$unit"
[ -n "${WAITER_HOLD:-}" ] && exit 0
"$@"; rm -f "$FX/active/user.$unit"
STUB
  printf '#!/usr/bin/env bash
echo "$*" >> "$FX/wait.log"
exit "${WAIT_RC:-0}"
' > "$FX/wait"
  chmod +x "$SANDBOX/bin/systemctl" "$SANDBOX/bin/pgrep" "$SANDBOX/bin/systemd-run" "$FX/wait"
  export MACHINE_MODE_WAIT_WORKER="$FX/wait"
}
active() { [ -e "$FX/active/$1" ]; }
# Not "! active": bats ignores a negated command's status on any line but the last.
inactive() { [ ! -e "$FX/active/$1" ]; }
busy() { echo "$FX/home/actions.runner.host-unity-pool-$1.service/bin.2.337.0/Runner.Worker spawnclient 1 2" >> "$FX/procs"; }

@test "a switch writes the mode's runners as the slot count, runs the slots under it and stops an idle one over it" {
  slots_fixture
  run "$MM" full
  assert_success
  assert_equal "$(cat "$MACHINE_MODE_SLOT_FILE")" 1
  active actions.runner.host-unity-pool-1.service
  inactive actions.runner.host-unity-pool-2.service
  [ ! -e "$FX/systemd-run.log" ]
  run "$MM" reserved
  assert_equal "$(cat "$MACHINE_MODE_SLOT_FILE")" 0
  inactive actions.runner.host-unity-pool-1.service
}

@test "a busy slot over the count stops once its job ends, and one waiter at a time" {
  slots_fixture
  busy 2
  WAITER_HOLD=1 run "$MM" full
  assert_success
  assert_output --partial "actions.runner.host-unity-pool-2.service: stops when its job ends"
  active actions.runner.host-unity-pool-2.service
  active user.machine-mode-drain-2
  WAITER_HOLD=1 run "$MM" full
  assert_equal "$(wc -l < "$FX/systemd-run.log")" 1
  # The waiter's own command: once the job ends it stops the slot, and on a timeout it leaves it.
  rm "$FX/active/user.machine-mode-drain-2"
  WAIT_RC=124 run "$MM" full
  active actions.runner.host-unity-pool-2.service
  run "$MM" full
  inactive actions.runner.host-unity-pool-2.service
  assert_equal "$(tail -1 "$FX/wait.log")" "^$FX/home/actions.runner.host-unity-pool-2.service/bin[^/]*/Runner.Worker 21600"
}

@test "a switch that runs a draining slot again cancels its waiter" {
  slots_fixture
  busy 2
  export MACHINE_MODE_MODES="$FX/modes"
  printf 'both|2|2|mid\none|1|2|mid\n' > "$MACHINE_MODE_MODES"
  WAITER_HOLD=1 run "$MM" one
  active user.machine-mode-drain-2
  run "$MM" both
  assert_success
  inactive user.machine-mode-drain-2
  active actions.runner.host-unity-pool-2.service
}

@test "a slot that will not start or stop leaves the switch unapplied, exit 1, and names the polkit rule" {
  slots_fixture
  SYSTEMCTL_FAIL=1 run "$MM" full
  assert_failure
  assert_output --partial "its polkit rule"
  assert_equal "$(state RUNNERS_PINNED)" no
}

@test "a host with no count directory starts and stops no slot" {
  run "$MM" full
  assert_success
  [ ! -e "$FX/ci-slots" ]
  [ ! -e "$FX/systemctl.log" ]
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
    done; done' _ "$REPO_ROOT/.local/lib/machine-mode.sh"
  assert_success
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

@test "a pin that failed at a part's start is retried on the next tick, and an old state file counts as by hand" {
  hours_fixture
  KUBE_FAIL=1 MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_failure
  assert_equal "$(state RUNNERS_PINNED) $(state CLOCK_PART)" "no night"
  MACHINE_MODE_NOW=23:15 run "$MM" clock
  assert_success
  assert_equal "$(state RUNNERS_PINNED)" yes
  printf 'MACHINE_MODE=reserved\nRUNNERS_PINNED=yes\n' > "$STATE"
  MACHINE_MODE_NOW=12:00 run "$MM" clock
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

@test "a tick that changes nothing exits 0 and says nothing; one whose pin fails exits 1" {
  hours_fixture
  MACHINE_MODE_NOW=12:00 run "$MM" clock
  assert_success
  MACHINE_MODE_NOW=12:15 run "$MM" clock
  assert_success
  assert_output ""
  MACHINE_MODE_NOW=12:00 "$MM" auto >/dev/null
  KUBE_FAIL=1 MACHINE_MODE_NOW=23:00 run "$MM" clock
  assert_failure 1
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

# The release lane: `release-lane` writes only "<host>.reserve" {"until": <epoch>}, which the governor
# reads as a pin to 0 until then (home-config governor.py read_pins).
reservation() { jq -r --arg k "$1.reserve" '.data[$k] | fromjson | .until' "$FX/cm.json"; }
# lane_prom <host>...: the governor reports on these hosts.
lane_prom() {
  jq -n '{status: "success", data: {result: [$ARGS.positional[] | {metric: {__name__: "ci_governor_registered", host: .}, value: [0, "2"]}]}}' \
    --args "$@" > "$FX/prom.json"
}

@test "release-lane writes the host's own reserve key with its end, and keeps every other key" {
  lane_prom lane-host "$HOST"
  jq -n --arg h "$HOST" '{data: {"lane-host.power": "{\"action\":\"off\",\"until\":5}", ($h + ".slots"): "{\"slots\":2,\"by\":\"x\"}"}}' > "$FX/cm.json"
  before="$(date +%s)"
  run "$MM" release-lane lane-host --until "6 hours"
  assert_success
  assert_output --partial "lane-host: reserved for release jobs until"
  end="$(reservation lane-host)"
  ((end >= before + 21600 && end <= before + 21610))
  assert_equal "$(jq -r '.data["lane-host.power"]' "$FX/cm.json")" '{"action":"off","until":5}'
  assert_equal "$(pin)" '{"slots":2,"by":"x"}'
  assert_equal "$(jq -c '.data | keys' "$FX/patches.log")" '["lane-host.reserve"]'
  [ ! -e "$STATE" ]
}

@test "release-lane works on a machine with no pool runners, since it pins another host" {
  lane_prom lane-host
  export MACHINE_MODE_RUNNER_UNITS="$FX/none-*.service"
  run "$MM" release-lane lane-host --until "2 hours"
  assert_success
  [ -n "$(reservation lane-host)" ]
}

@test "release-lane refuses a past, unreadable or over-a-day end, and a missing --until, writing nothing" {
  lane_prom lane-host
  for args in "lane-host --until yesterday" "lane-host --until notatime" "lane-host --until 30hours" \
      "lane-host" "lane-host --until" "Razer_Laptop --until 2hours"; do
    # shellcheck disable=SC2086
    run "$MM" release-lane $args
    assert_failure
  done
  run "$MM" release-lane lane-host --until "2 days"
  assert_failure
  assert_output --partial "more than 24h ahead"
  run "$MM" release-lane lane-host --until "1 hour ago"
  assert_output --partial "say 'tomorrow"
  [ ! -e "$FX/cm.json" ]
}

@test "release-lane refuses a host the governor does not report, and goes on with a warning when Prometheus is down" {
  lane_prom lane-host
  run "$MM" release-lane lane-hsot --until "2 hours"
  assert_failure
  assert_output --partial "the governor runs no host 'lane-hsot'"
  [ ! -e "$FX/cm.json" ]
  CURL_FAIL=1 run "$MM" release-lane lane-host --until "2 hours"
  assert_success
  assert_output --partial "warning: cannot read Prometheus"
  [ -n "$(reservation lane-host)" ]
}

@test "the list shows each reservation in local time and marks an ended one; clear removes the key" {
  lane_prom lane-host
  "$MM" release-lane lane-host --until "3 hours"
  jq --argjson past "$(( $(date +%s) - 60 ))" '.data["mac-studio.reserve"] = ({until: $past} | tojson)' "$FX/cm.json" > "$FX/cm.new"
  mv "$FX/cm.new" "$FX/cm.json"
  run "$MM" release-lane
  assert_success
  assert_line --regexp '^lane-host: until [0-9]{4}-[0-9]{2}-[0-9]{2} [0-9]{2}:[0-9]{2} [A-Z+0-9-]+$'
  assert_line --regexp '^mac-studio: until .*, ended$'
  run "$MM" release-lane --clear lane-host
  assert_success
  assert_output --partial "reservation ended"
  assert_equal "$(jq -r '.data | has("lane-host.reserve")' "$FX/cm.json")" false
  assert_equal "$(jq -r '.data | has("mac-studio.reserve")' "$FX/cm.json")" true
  assert_equal "$(tail -n1 "$FX/patches.log")" '{"data":{"lane-host.reserve":null}}'
  rm "$FX/patches.log"
  run "$MM" release-lane --clear lane-host
  assert_success
  assert_output "lane-host: no reservation"
  [ ! -e "$FX/patches.log" ]
}

@test "an unreachable cluster or no kube context fails the reservation" {
  KUBE_FAIL=1 run "$MM" release-lane lane-host --until "2 hours"
  assert_failure
  CC_KUBE_CONTEXT= run "$MM" release-lane lane-host --until "2 hours"
  assert_failure
  assert_output --partial "CC_KUBE_CONTEXT is not set"
}
