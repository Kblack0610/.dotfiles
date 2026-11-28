#!/usr/bin/env bats
# fleet-bench health: one row per part of the fleet, joined from the architecture doc's parts,
# each watch's `flows:` tags and Sentinel's own <watch>.state. A fixture doc, watch dir and state
# dir stand in for the real ones, so no test reads the live fleet.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  SUBJECT="$REPO_ROOT/.local/bin/fleet-bench"
  SM="$REPO_ROOT/.local/bin/sentinel-manifest"
  export HEALTH_MANIFEST_CMD="$SM" BENCH_LIB_DIR="$REPO_ROOT/.local/lib"
  export FLEET_ARCH_DOC="$SANDBOX/ARCHITECTURE.md" HEALTH_EXCLUDE="$SANDBOX/health-exclude"
  export TRIAGE_WATCHES="$SANDBOX/watches" TRIAGE_WATCH_STATE="$SANDBOX/state"
  mkdir -p "$TRIAGE_WATCHES" "$TRIAGE_WATCH_STATE"
  cat > "$FLEET_ARCH_DOC" <<'EOF'
# Fleet architecture

## Runners

| Piece | Where | Rule |
| --- | --- | --- |

## Asks

An ask is pending.

## Flows

| Flow | Question | Defined in | Picture | Checked by |
| --- | --- | --- | --- | --- |
| Dispatch | What starts a session? | `a.md` | - | none |
| Asks | How does an ask live? | `b.md` | - | none |
| Lifecycle | Which step? | `c.md` | - | none |

## Instruments

| Question | Skill | Run | Last result |
| --- | --- | --- | --- |
| Not a part | x | y | z |
EOF
  watch runner-watch OK '[Runners]'
  watch queue-watch OK '[Dispatch, Asks]'
}

# watch <name> <state> <flows-yaml>: a manifest tagged with flows, and the state Sentinel last wrote
watch() {
  printf 'name: %s\nprobe: command\nexpect_cmd: "true"\nflows: %s\n' "$1" "$3" > "$TRIAGE_WATCHES/$1.yaml"
  printf '%s' "$2" > "$TRIAGE_WATCH_STATE/$1.state"; date +%s > "$TRIAGE_WATCH_STATE/$1.lastrun"
}

@test "parts are the headings above Flows plus the Flows rows, once each, and nothing below" {
  run "$SM" parts
  assert_success
  assert_output $'Runners\nAsks\nDispatch\nLifecycle'
}

@test "a part named in health-exclude is left out of the parts list" {
  printf '# why\nLifecycle\tprocess doc, no runtime behaviour\n' > "$HEALTH_EXCLUDE"
  run "$SM" parts
  assert_success
  assert_output $'Runners\nAsks\nDispatch'
}

@test "health: a tagged part is OK, an untagged one UNCOVERED, and the verdict line counts both" {
  run "$SUBJECT" health
  assert_success
  assert_line --regexp '^Runners +OK +runner-watch=OK$'
  assert_line --regexp '^Dispatch +OK +queue-watch=OK$'
  assert_line --regexp '^Lifecycle +UNCOVERED +-$'
  assert_line 'fleet health GAPS: 4 parts, 3 OK, 0 TRIP, 0 ERROR, 1 UNCOVERED'
}

@test "health negative control: removing a watch's tag shows the part UNCOVERED and --coverage exits 1" {
  run "$SUBJECT" health --coverage
  assert_failure
  assert_output 'Lifecycle'
  watch runner-watch OK '[]'
  run "$SUBJECT" health --coverage
  assert_failure
  assert_output $'Runners\nLifecycle'
}

@test "health: every part covered is GREEN, exits 0, and --coverage is silent" {
  watch life-watch OK '[Lifecycle]'
  run "$SUBJECT" health
  assert_success
  assert_line 'fleet health GREEN: 4 parts, 4 OK, 0 TRIP, 0 ERROR, 0 UNCOVERED'
  run "$SUBJECT" health --coverage
  assert_success
  assert_output ''
}

# The fleet-health-coverage watch runs `fleet-bench health --coverage` and trips on its exit 1, so
# these cases are what it guards: a new Flows row, a watch deleted without a replacement, a renamed row.
@test "health --coverage guard: a new Flows row with no watch exits 1 and names the part" {
  watch life-watch OK '[Lifecycle]'
  printf '| Admission | What caps the queue? | `d.md` | - | none |\n' > "$SANDBOX/row"
  sed -i "/^| Lifecycle /r $SANDBOX/row" "$FLEET_ARCH_DOC"
  grep -q '^| Admission ' "$FLEET_ARCH_DOC"
  run "$SUBJECT" health --coverage
  assert_failure
  assert_output 'Admission'
}

@test "health --coverage guard: a watch deleted without a replacement uncovers its part" {
  watch life-watch OK '[Lifecycle]'
  run "$SUBJECT" health --coverage
  assert_success
  rm "$TRIAGE_WATCHES/life-watch.yaml" "$TRIAGE_WATCH_STATE/life-watch.state"
  run "$SUBJECT" health --coverage
  assert_failure
  assert_output 'Lifecycle'
}

@test "health --coverage guard: a Flows row renamed under a watch's tag exits 1 and names the stale tag" {
  watch life-watch OK '[Lifecycle]'
  sed -i 's/^| Lifecycle /| Life cycle /' "$FLEET_ARCH_DOC"
  run "$SUBJECT" health --coverage
  assert_failure
  assert_output --partial 'Lifecycle'
  assert_output --partial 'Life cycle'
}

@test "health negative control: a tripped watch makes its parts TRIP, the verdict RED, and the exit 1" {
  printf TRIP > "$TRIAGE_WATCH_STATE/queue-watch.state"
  run "$SUBJECT" health
  assert_failure
  assert_line --regexp '^Dispatch +TRIP +queue-watch=TRIP$'
  assert_line --regexp '^Asks +TRIP +queue-watch=TRIP$'
  assert_line --regexp '^Runners +OK '
  assert_line --partial 'fleet health RED: 4 parts, 1 OK, 2 TRIP, 0 ERROR, 1 UNCOVERED (down: Asks, Dispatch)'
}

@test "health: a quarantined red reads TRIP/Q, a warning that turns no part red, and a live TRIP still wins" {
  printf TRIP > "$TRIAGE_WATCH_STATE/queue-watch.state"
  printf '%s ar-1 %s waits on a fix\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" > "$TRIAGE_WATCH_STATE/queue-watch.quarantine"
  run "$SUBJECT" health
  assert_line --regexp '^Dispatch +TRIP/Q +queue-watch=TRIP/Q$'
  assert_line --partial 'fleet health GAPS: 4 parts, 1 OK, 0 TRIP, 0 ERROR, 1 UNCOVERED, 2 TRIP/Q (quarantined: Asks, Dispatch)'
  watch live-red TRIP '[Dispatch]'
  run "$SUBJECT" health
  assert_failure
  assert_line --regexp '^Dispatch +TRIP '
  assert_line --partial '1 TRIP/Q (down: Dispatch) (quarantined: Asks)'
}

@test "health: a quarantined watch that names a red its quarantine does not cover reads TRIP, not TRIP/Q (ar-3916)" {
  printf TRIP > "$TRIAGE_WATCH_STATE/queue-watch.state"
  printf '%s ar-1 %s waits on a fix\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" > "$TRIAGE_WATCH_STATE/queue-watch.quarantine"
  printf 'TRIP exit 1\nRED dispatch 3 rows stuck\n' > "$TRIAGE_WATCH_STATE/queue-watch.quarantine.covers"
  printf 'TRIP exit 1\nRED dispatch 5 rows stuck\n' > "$TRIAGE_WATCH_STATE/queue-watch.out"
  run "$SUBJECT" health
  assert_line --regexp '^Dispatch +TRIP/Q +queue-watch=TRIP/Q$'
  printf 'TRIP exit 1\nRED dispatch 5 rows stuck\nRED asks unread\n' > "$TRIAGE_WATCH_STATE/queue-watch.out"
  run "$SUBJECT" health
  assert_failure
  assert_line --regexp '^Dispatch +TRIP +queue-watch=TRIP$'
}

@test "health: every part covered with one quarantined reads GAPS, not GREEN, and exits 0; a zero-padded UNTIL is decimal" {
  watch lifecycle-watch OK '[Lifecycle]'
  printf TRIP > "$TRIAGE_WATCH_STATE/runner-watch.state"
  printf '0%s ar-1 %s waits on a fix\n' "$(( $(date +%s) + 3600 ))" "$(date +%s)" > "$TRIAGE_WATCH_STATE/runner-watch.quarantine"
  run "$SUBJECT" health
  assert_success
  assert_line --regexp '^Runners +TRIP/Q '
  assert_line --partial 'fleet health GAPS: 4 parts, 3 OK, 0 TRIP, 0 ERROR, 0 UNCOVERED, 1 TRIP/Q (quarantined: Runners)'
}

@test "health negative control: a quarantine past its UNTIL reads red again" {
  printf TRIP > "$TRIAGE_WATCH_STATE/queue-watch.state"
  printf '%s ar-1 %s waits on a fix\n' "$(( $(date +%s) - 60 ))" "$(( $(date +%s) - 7200 ))" > "$TRIAGE_WATCH_STATE/queue-watch.quarantine"
  run "$SUBJECT" health
  assert_failure
  assert_line --regexp '^Dispatch +TRIP +queue-watch=TRIP$'
  assert_line --partial 'fleet health RED: 4 parts, 1 OK, 2 TRIP'
  refute_output --partial 'quarantined:'
}

@test "health: a part takes its worst live watch, ERROR over TRIP over OK" {
  watch second OK '[Runners]'
  watch third TRIP '[Runners]'
  run "$SUBJECT" health
  assert_failure
  assert_line --regexp '^Runners +TRIP '
  watch fourth ERROR '[Runners]'
  run "$SUBJECT" health
  assert_line --regexp '^Runners +ERROR '
}

@test "health: a watch with no reading yet shows beside its part but does not cover it" {
  rm "$TRIAGE_WATCH_STATE/runner-watch.state"
  run "$SUBJECT" health
  assert_line --regexp '^Runners +UNCOVERED +runner-watch=new$'
}

@test "health: a paused watch (.yaml.paused) is not a probe" {
  mv "$TRIAGE_WATCHES/runner-watch.yaml" "$TRIAGE_WATCHES/runner-watch.yaml.paused"
  run "$SUBJECT" health
  assert_line --regexp '^Runners +UNCOVERED +-$'
}

@test "health: a flows name that is no part is reported stale, by health and by --coverage" {
  watch old-watch OK '[Delivery chain]'
  run "$SUBJECT" health
  assert_line --regexp '^\? +STALE +old-watch names Delivery chain$'
  assert_line --partial '1 stale flows names'
  run "$SUBJECT" health --coverage
  assert_failure
  assert_line 'stale flows name: old-watch names Delivery chain'
}

@test "health: an unreadable manifest tags nothing, so its part reads UNCOVERED, not missing" {
  printf 'name: [unterminated\n' > "$TRIAGE_WATCHES/runner-watch.yaml"
  run "$SUBJECT" health
  assert_line --regexp '^Runners +UNCOVERED +-$'
}

@test "health: an unreadable architecture doc fails closed rather than reading as an empty fleet" {
  rm "$FLEET_ARCH_DOC"
  run "$SUBJECT" health
  assert_failure
  assert_output --partial 'cannot read the parts list'
}

@test "health: an unknown flag is a usage error" {
  run "$SUBJECT" health --nope
  assert_failure 2
}

@test "validate: flows must be a list of names; plain validate does not check them against the doc" {
  base="$BATS_TEST_TMPDIR/w.yaml"
  printf 'probe: command\nexpect_cmd: "true"\nflows: [Runners, Not A Part]\n' > "$base"
  run "$SM" validate "$base"
  assert_success
  printf 'probe: command\nexpect_cmd: "true"\nflows: []\n' > "$base"
  run "$SM" validate "$base"
  assert_failure
  assert_output --partial 'flows must be a list'
}

@test "validate --strict rejects a flows name that is not a part and accepts one that is" {
  base="$BATS_TEST_TMPDIR/w.yaml"
  printf 'what: a\nwhy: b\nwhere: c\naction: d\nprobe: command\nexpect_cmd: "true"\nexpiry: null\nsystem: telemetry\nflows: [Runners, Not A Part]\n' > "$base"
  run "$SM" validate --strict "$base"
  assert_failure
  assert_output --partial "'Not A Part', which is not a part of the fleet"
  sed -i 's/, Not A Part//' "$base"
  run "$SM" validate --strict "$base"
  assert_success
}

@test "env: a flows list is one W_flows_N variable each and the loop's readers ignore the rest" {
  printf 'probe: command\nexpect_cmd: "true"\nflows: [Runners, Delivery chain]\n' > "$BATS_TEST_TMPDIR/w.yaml"
  run "$SM" env "$BATS_TEST_TMPDIR/w.yaml"
  assert_success
  assert_line 'W_flows_count=2'
  assert_line "W_flows_1='Delivery chain'"
}

@test "health negative control: a reading older than the watch's poll window is STALE and counts as ERROR, so a dead Sentinel is never GREEN" {
  echo $(( $(date +%s) - 7200 )) > "$TRIAGE_WATCH_STATE/runner-watch.lastrun"   # the manifest has no interval: 300s default, 3 windows
  run "$SUBJECT" health
  assert_failure
  assert_line --regexp '^Runners +ERROR +runner-watch=STALE$'
  assert_line --partial 'fleet health RED'
  rm "$TRIAGE_WATCH_STATE/runner-watch.lastrun"   # never polled: its state says so, it is not called stale
  run "$SUBJECT" health
  assert_line --regexp '^Runners +OK +runner-watch=OK$'
}

@test "health: stderr noise from the manifest tool is not read as a part or a tag" {
  printf '#!/usr/bin/env bash\necho "DeprecationWarning: noise" >&2\nexec "%s" "$@"\n' "$SM" > "$SANDBOX/bin/sm-noisy"
  chmod +x "$SANDBOX/bin/sm-noisy"
  HEALTH_MANIFEST_CMD=sm-noisy run "$SUBJECT" health --coverage
  assert_failure
  assert_output 'Lifecycle'
}

@test "health: --json, which nothing read, is a usage error" {
  run "$SUBJECT" health --json
  assert_failure 2
}

@test "tags: a null or mapping entry in flows: is no name" {
  printf 'probe: command\nexpect_cmd: "true"\nflows: [Runners, null, {a: b}]\n' > "$TRIAGE_WATCHES/odd.yaml"
  run "$SM" tags "$TRIAGE_WATCHES"
  assert_output --partial $'odd\tRunners'
  refute_output --partial 'None'
  refute_output --partial "{"
}
