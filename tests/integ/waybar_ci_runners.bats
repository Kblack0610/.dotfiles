#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It renders `hub ci --json` .glance, the slot model
# hub-core computes for every CI surface. What these pin: the bar is the glance's busy/slots
# (each slot once) and queue; its colour and class are the ci domain level, never its own
# judgement; the hover is the board's head line, jobs by kind, one row per machine with what
# its slots are doing and space last, the stopped cloud hosts on one line, down and long
# runs; and a failed hub read shows `CI: prom down`, never the last numbers.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ci_runners.sh"
  export FX="$BATS_TEST_TMPDIR" HUB="$BATS_TEST_TMPDIR/hub"
  cat > "$HUB" <<'STUB'
#!/usr/bin/env bash
[ "$*" = "ci --json" ] || exit 2
[ -n "${HUB_FAIL:-}" ] && { echo "hub ci: cannot read http://prom.test <x>" >&2; exit 1; }
[ -n "${HUB_WARN:-}" ] && echo "warning: slow scrape" >&2
cat "$FX/ci.json"
STUB
  chmod +x "$HUB"
  glance '{}'
}

# glance <jq patch>: a warn glance, 2/3 busy, 2 queued, 4 done at 75%, one stopped cloud
# host, then the patch merged over it.
glance() {
  jq -n --argjson patch "$1" '{glance: ({
    level: "warn", parts: [{name: "pools", level: "warn"}, {name: "watches", level: "ok"}],
    feed: null, busy: 2, slots: 3, queued: 2, oldest: 900, done: 4, pass: 0.75,
    kinds: [{kind: "unity", waiting: 2, oldest: 900, done: 2, pass: 0.5},
            {kind: "github-hosted", waiting: null, oldest: null, done: 2, pass: 1}],
    machines: [{host: "workstation", busy: 2, slots: 2, doing: "1 gates, 1 unity, 1 held", space: "12/60G 1.5T free"},
               {host: "mac-mini", busy: 0, slots: 1, doing: "1 free", space: "482G free"}],
    off: ["aws-burst-1"], down: [], long: []} * $patch)}' > "$FX/ci.json"
}

bar()  { jq -r .text <<< "$output"; }
tip()  { jq -r .tooltip <<< "$output"; }
plain() { jq -r .tooltip <<< "$output" | sed -E 's/<[^>]+>//g'; }

@test "the bar is busy of slots, each slot once, and the queue, coloured by the ci level" {
  run "$MODULE"
  assert_success
  assert_equal "$(bar)" "<span color='#ffcc2f'>CI</span> 2/3 <span color='#ffcc2f'>q2</span>"
  assert_equal "$(jq -r .class <<< "$output")" warn
}

@test "a green level leaves the label plain and an empty queue reads q0 plain" {
  glance '{"level": "ok", "queued": 0, "busy": 0}'
  run "$MODULE"
  assert_equal "$(bar)" "CI 0/3 q0"
  assert_equal "$(jq -r .class <<< "$output")" ok
}

@test "a red level is critical" {
  glance '{"level": "red"}'
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" critical
  [[ "$(bar)" == "<span color='#ef5734'>CI</span>"* ]]
}

@test "no status series is no data, never green" {
  glance '{"level": "nodata", "parts": []}'
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" warn
  assert_equal "$(tip | sed -n 2p)" "ci: no data"
}

@test "the head line is the board's, the pass rate painted amber under 90%" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>  2/3 busy, 2 queued (oldest 15m), 4 done 24h, <span color='#ffcc2f'>75% passed</span>"
  glance '{"pass": 0.5}'
  run "$MODULE"
  [[ "$(tip | sed -n 1p)" == *"<span color='#ef5734'>50% passed</span>" ]]
  glance '{"queued": 0, "pass": 0.95}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 1p)" "CI runners  2/3 busy, 0 queued, 4 done 24h, 95% passed"
}

@test "the parts line paints each level, and a short feed says why in red" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 2p)" "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
  glance '{"feed": "runner exporter missed its last scrape: runner rows may be missing"}'
  run "$MODULE"
  [[ "$(tip | sed -n 2p)" == *", <span color='#ef5734'>runner exporter missed its last scrape: runner rows may be missing</span>" ]]
}

@test "jobs by kind: waiting, oldest, done and pass, no capacity column" {
  run "$MODULE"
  run plain
  assert_line --index 2 "KIND          WAITING OLDEST  DONE  PASS"
  assert_line --index 3 "unity               2    15m     2  50%"
  assert_line --index 4 "github-hosted       -      -     2  100%"
  refute_output --partial "SLOTS"
}

@test "one row per machine: busy/slots, what its slots do, space last; no WHERE, no pool names" {
  run "$MODULE"
  run plain
  assert_line "MACHINE      BUSY  DOING                     SPACE"
  assert_line "workstation   2/2  1 gates, 1 unity, 1 held  12/60G 1.5T free"
  assert_line "mac-mini      0/1  1 free                    482G free"
  assert_line "cloud: 1 host off"
  refute_output --partial "WHERE"
  refute_output --partial "local:workstation"
  refute_output --partial "other"
}

@test "stopped cloud hosts fold to one line and are never down" {
  glance '{"off": ["aws-spot-1", "aws-spot-2"], "down": [{"host": "windows-media", "state": "offline", "n": 1}]}'
  run "$MODULE"
  run plain
  assert_line "cloud: 2 hosts off"
  assert_line "DOWN:"
  assert_line "  windows-media  1 offline"
  refute_output --partial "aws-spot-1"
}

@test "nothing off or down draws neither line" {
  glance '{"off": []}'
  run "$MODULE"
  run plain
  refute_output --partial "cloud:"
  refute_output --partial "DOWN"
}

@test "long runs are one amber line with their time" {
  glance '{"long": [{"what": "ms-a2 Multi game#2210", "ran": 8880}]}'
  run "$MODULE"
  [[ "$(tip)" == *"<span color='#ffcc2f'>long runs: ms-a2 Multi game#2210 2h28m</span></tt>" ]]
}

@test "a failed hub read is prom down, never the last numbers, and its reason is escaped" {
  HUB_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(bar)" "<span color='#ef5734'>CI: prom down</span>"
  assert_equal "$(jq -r .class <<< "$output")" critical
  assert_equal "$(tip)" "CI runners: hub ci: cannot read http://prom.test &lt;x&gt;"
}

@test "output that is not a glance is prom down" {
  echo 'not json' > "$FX/ci.json"
  run "$MODULE"
  assert_equal "$(bar)" "<span color='#ef5734'>CI: prom down</span>"
  echo '{"local": []}' > "$FX/ci.json"
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" critical
}

@test "machine and kind names are escaped for pango after padding, so columns still line up" {
  glance '{"machines": [{"host": "a<b", "busy": 0, "slots": 1, "doing": "1 free", "space": "-"}],
           "kinds": [{"kind": "x&y", "waiting": 0, "oldest": null, "done": 1, "pass": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *"a&lt;b       0/1  1 free  -"* ]]
  [[ "$(tip)" == *"x&amp;y        0      -     1  100%"* ]]
}

@test "a warning on stderr does not break the read" {
  HUB_WARN=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" warn
}
