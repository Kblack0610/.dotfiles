#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It renders `hub ci --json` .glance, the slot model
# hub-core computes for every CI surface. What these pin: the bar is
# busy/capacity slot units (the machine rows' sum), the queue and its drain time; its colour and class are the ci domain level, never its own
# judgement; the hover is each machine's cells on the title line, the board's head line in units, jobs by kind, one row per machine with
# a cell per capacity unit (a taken fraction as an eighth block), what runs there and the next waiting job that fits it (red past the load chip's HOT_RATIO), the
# stopped cloud hosts on one line, down and long runs; and a failed hub read shows `CI: prom down`, never the last numbers.

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

# glance <jq patch>: a warn glance, 2 queued, 4 done at 75%, 1.4 of 4 slot units busy
# (workstation 1.4 of 3, mac-mini 0 of 1) and 2 units waiting that drain in 15m, one
# stopped cloud host, nothing WAITING, then the patch merged over it.
glance() {
  jq -n --argjson patch "$1" '{glance: ({
    level: "warn", parts: [{name: "pools", level: "warn"}, {name: "watches", level: "ok"}],
    feed: null, busy: 2, slots: 3, queued: 2, oldest: 900, done: 4, pass: 0.75,
    units_busy: 1.4, units: 4, backlog: 2, drain: 900,
    kinds: [{kind: "unity", running: 2, waiting: 2, oldest: 900, done: 2, pass: 0.5},
            {kind: "github-hosted", waiting: null, oldest: null, done: 2, pass: 1}],
    machines: [{host: "workstation", busy: 2, slots: 2, running: ["gates", "unity platform"], next: null, load: 0.4,
                units: 3, units_busy: 1.4},
               {host: "mac-mini", busy: 0, slots: 1, running: [], next: {job: "Checks", repo: "web", n: 1, wait: 300}, load: null,
                units: 1, units_busy: 0}],
    off: ["aws-burst-1"], down: [], long: [], next: []} * $patch)}' > "$FX/ci.json"
}

# The live shape the human asked about (2026-11-19): deskslim-2 is 3 Unity slots, two busy and
# the third lent to seats at 0.48 of a slot, however many runners are registered on it.
deskslim() {
  glance '{"units_busy": 8.48, "units": 14, "drain": 720, "machines": [
    {"host": "deskslim-1", "busy": 3, "slots": 3, "running": ["unity unity-core-playground x3"], "next": null, "load": 0.2, "units": 3, "units_busy": 3},
    {"host": "deskslim-2", "busy": 4, "slots": 6, "running": ["unity unity-core-playground x2", "light home-config"], "next": null, "load": 0.2, "units": 3, "units_busy": 2.48},
    {"host": "ms-a2", "busy": 3, "slots": 3, "running": ["unity platform x3"], "next": null, "load": 0.2, "units": 5, "units_busy": 3},
    {"host": "workstation", "busy": 0, "slots": 1, "running": [], "next": null, "load": 0.2, "units": 3, "units_busy": 0}]}'
}

bar()  { jq -r .text <<< "$output"; }
tip()  { jq -r .tooltip <<< "$output"; }
plain() { jq -r .tooltip <<< "$output" | sed -E 's/<[^>]+>//g'; }

@test "the bar is busy of capacity units, the queue and its drain, coloured by the ci level" {
  run "$MODULE"
  assert_success
  assert_equal "$(bar)" "<span color='#ffcc2f'>CI</span> 1.4/4 <span color='#ffcc2f'>q2</span> ~15m"
  assert_equal "$(jq -r .class <<< "$output")" warn
}

@test "a green level leaves the label plain and an empty queue reads q0 plain" {
  glance '{"level": "ok", "queued": 0, "units_busy": 0, "units": 3}'
  run "$MODULE"
  assert_equal "$(bar)" "CI 0.0/3 q0"
  assert_equal "$(jq -r .class <<< "$output")" ok
}

@test "deskslim-2 is its 3 slots however many runners share them: 2.48 busy is two full cells and a half one on the dim colour" {
  deskslim
  run "$MODULE"
  assert_equal "$(bar)" "<span color='#ffcc2f'>CI</span> 8.5/14 <span color='#ffcc2f'>q2</span> ~12m"
  [[ "$(tip)" == *$'\ndeskslim-2  2.5/3  ██<span background=\'#7f7f7f\'>▌</span>    unity unity-core-playground x2, light home-config  -\n'* ]]
  # A machine with nothing taken is all dim cells.
  [[ "$(tip)" == *$'\nworkstation 0.0/3  <span color=\'#7f7f7f\'>███</span>    -  '* ]]
  run plain
  assert_line "MACHINE     TAKEN         RUNNING                                            NEXT"
  assert_line "deskslim-1  3.0/3  ███    unity unity-core-playground x3                     -"
  assert_line "ms-a2       3.0/5  █████  unity platform x3                                  -"
  assert_line --index 1 "8.5/14 busy, 2 queued (oldest 15m), 2.0 queued ~12m, 4 done 24h, 75% passed"
}

@test "the title is each machine's cells, a group per machine, so the cells read per machine" {
  deskslim
  run "$MODULE"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>  ███ ██<span background='#7f7f7f'>▌</span> ███<span color='#7f7f7f'>██</span> <span color='#7f7f7f'>███</span>"
}

@test "a fraction rounds to the nearest eighth, and one that rounds up to 8 is a full cell" {
  glance '{"machines": [
    {"host": "a", "busy": 1, "slots": 2, "running": ["x"], "next": null, "load": 0.2, "units": 2, "units_busy": 0.1},
    {"host": "b", "busy": 1, "slots": 2, "running": ["x"], "next": null, "load": 0.2, "units": 2, "units_busy": 0.97}]}'
  run "$MODULE"
  [[ "$(tip)" == *$'\na       0.1/2  <span background=\'#7f7f7f\'>▏</span><span color=\'#7f7f7f\'>█</span>'* ]]
  [[ "$(tip)" == *$'\nb       1.0/2  █<span color=\'#7f7f7f\'>█</span>'* ]]
}

@test "the bar reads slot units, the queue and its drain time: CI 6.4/16 q9 ~12m (hc-668)" {
  glance '{"level": "ok", "queued": 9, "units_busy": 6.4, "units": 16, "backlog": 9.2, "drain": 720}'
  run "$MODULE"
  assert_equal "$(bar | sed -E 's/<[^>]+>//g')" "CI 6.4/16 q9 ~12m"
  assert_equal "$(plain | sed -n 2p)" "6.4/16 busy, 9 queued (oldest 15m), 9.2 queued ~12m, 4 done 24h, 75% passed"
}

@test "with no governor unit series every unit field is a dash and no cell is drawn, never a runner count as capacity" {
  glance '{"units_busy": null, "units": null, "backlog": null, "drain": null, "machines": [
    {"host": "workstation", "busy": 2, "slots": 2, "running": ["gates", "unity platform"], "next": null, "load": 0.4, "units": null, "units_busy": null}]}'
  run "$MODULE"
  assert_equal "$(bar | sed -E 's/<[^>]+>//g')" "CI -/- q2 -"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>"
  assert_equal "$(plain | sed -n 2p)" "-/- busy, 2 queued (oldest 15m), - queued -, 4 done 24h, 75% passed"
  run plain
  assert_line "workstation     -         gates, unity platform  -"
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
  assert_equal "$(tip | sed -n 3p)" "ci: no data"
}

@test "the head line is the board's, in units, the pass rate painted amber under 90%" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 2p)" "1.4/4 busy, 2 queued (oldest 15m), 2.0 queued ~15m, 4 done 24h, <span color='#ffcc2f'>75% passed</span>"
  glance '{"pass": 0.5}'
  run "$MODULE"
  [[ "$(tip | sed -n 2p)" == *"<span color='#ef5734'>50% passed</span>" ]]
  glance '{"queued": 0, "pass": 0.95}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "1.4/4 busy, 0 queued, 4 done 24h, 95% passed"
}

@test "the parts line paints each level, and a short feed says why in red" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 3p)" "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
  glance '{"feed": "runner exporter missed its last scrape: runner rows may be missing"}'
  run "$MODULE"
  [[ "$(tip | sed -n 3p)" == *", <span color='#ef5734'>runner exporter missed its last scrape: runner rows may be missing</span>" ]]
}

@test "jobs by kind: running, waiting, oldest, done and pass, no FREE; none read is a dash" {
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND          RUNNING WAITING OLDEST  DONE  PASS"
  assert_line --index 4 "unity               2       2    15m     2  50%"
  assert_line --index 5 "github-hosted       -       -      -     2  100%"
  refute_output --partial "FREE"
}

@test "a kind reads its own jobs running, never the busy slots that carry its cap" {
  glance '{"kinds": [{"kind": "heavy", "running": 0, "busy": 7, "slots": 9, "waiting": 0, "oldest": null, "done": 2, "pass": 0.5}]}'
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND  RUNNING WAITING OLDEST  DONE  PASS"
  assert_line --index 4 --regexp '^heavy +0 +0 '
  refute_output --partial "7/9"
}

@test "one row per machine: TAKEN units and a cell per unit, RUNNING by kind and repo, NEXT the oldest waiting job that fits; no held, no SPACE, no WHERE, no pool names" {
  run "$MODULE"
  [[ "$(tip)" == *$'\nworkstation 1.4/3  █<span background=\'#7f7f7f\'>▍</span><span color=\'#7f7f7f\'>█</span>    gates, unity platform'* ]]
  run plain
  assert_line "MACHINE     TAKEN         RUNNING                NEXT"
  assert_line "workstation 1.4/3  █▍█    gates, unity platform  -"
  assert_line "mac-mini    0.0/1  █      -                      Checks (web) 5m"
  assert_line "cloud: 1 host off"
  refute_output --partial "held"
  refute_output --partial "WHERE"
  refute_output --partial "SPACE"
  refute_output --partial "local:workstation"
  refute_output --partial "other"
  refute_output --partial "DOING"
  refute_output --partial "SLOTS"
}

@test "a machine at or past the load chip's HOT_RATIO has a red name and taken count; under it, or no reading, stays plain" {
  glance '{"machines": [
    {"host": "ms-a2", "busy": 4, "slots": 4, "running": ["unity platform x4"], "next": null, "load": 1.5, "units": 4, "units_busy": 4},
    {"host": "razer", "busy": 1, "slots": 3, "running": ["unity platform"], "next": null, "load": 1.49, "units": 3, "units_busy": 1},
    {"host": "mac-mini", "busy": 0, "slots": 1, "running": [], "next": null, "load": null, "units": 1, "units_busy": 0}]}'
  run "$MODULE"
  [[ "$(tip)" == *"<span color='#ef5734'>ms-a2    4.0/4</span>  ████   unity platform x4  -"* ]]
  [[ "$(tip)" == *$'\nrazer    1.0/3  █<span color=\'#7f7f7f\'>██</span>    unity platform     -\n'* ]]
  [[ "$(tip)" == *$'\nmac-mini 0.0/1  <span color=\'#7f7f7f\'>█</span>      -                  -'* ]]
}

@test "a machine with more cells than the header widens the TAKEN bar for every row, RUNNING and NEXT still lined up" {
  glance '{"machines": [
    {"host": "ms-a2", "busy": 4, "slots": 7, "running": ["unity platform x4"], "next": null, "load": 0.2, "units": 7, "units_busy": 4},
    {"host": "mac-mini", "busy": 0, "slots": 1, "running": [], "next": {"job": "Soak", "repo": "", "n": 2, "wait": 90}, "load": null, "units": 1, "units_busy": 0}]}'
  run "$MODULE"
  run plain
  assert_line "MACHINE  TAKEN           RUNNING            NEXT"
  assert_line "ms-a2    4.0/7  ███████  unity platform x4  -"
  assert_line "mac-mini 0.0/1  █        -                  Soak 1m"
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
  [[ "$(tip)" == *"<span color='#ffcc2f'>long runs: ms-a2 Multi game#2210 2h28m</span>"* ]]
}

@test "WAITING: each waiting group with where it fits and about when it starts, then where every runner is" {
  glance '{"next": [
    {"job": "Soak", "repo": "game", "n": 1, "wait": 3480, "stuck": false, "at": "razer", "starts": 1320, "can": [{"host": "razer", "state": "busy"}]},
    {"job": "Wide", "repo": "", "n": 2, "wait": 30, "stuck": false, "at": "aws", "starts": 0, "can": [{"host": "aws", "state": "idle"}]},
    {"job": "cron", "repo": "home-config", "n": 7, "wait": 960, "stuck": false, "at": "ms-a2", "starts": null, "can": [{"host": "ms-a2", "state": "seat"}]},
    {"job": "HD", "repo": "game", "n": 1, "wait": 100, "stuck": true, "at": "", "starts": null, "can": []}]}'
  run "$MODULE"
  run plain
  assert_line "WAITING             N WAITED  WHERE       STARTS"
  assert_line "Soak (game)         1    58m  razer       in 22m"
  assert_line "Wide                2    30s  aws         now"
  assert_line "cron (home-config)  7    16m  ms-a2 seat  -"
  assert_line "HD (game)           1     1m  nobody      -"
  assert_line "every runner: hub --tab 'infra ci', agent-web #infra/machines/&lt;host&gt;"
}

@test "nothing waiting draws no WAITING list, still the every-runner line" {
  run "$MODULE"
  run plain
  refute_output --partial "WAITING  "
  assert_line "every runner: hub --tab 'infra ci', agent-web #infra/machines/&lt;host&gt;"
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
  glance '{"machines": [{"host": "a<b", "busy": 0, "slots": 1, "running": [], "next": null, "load": 0.2, "units": 1, "units_busy": 0}],
           "kinds": [{"kind": "x&y", "waiting": 0, "oldest": null, "done": 1, "pass": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *"a&lt;b     0.0/1  <span color='#7f7f7f'>█</span>      -        -"* ]]
  [[ "$(tip)" == *"x&amp;y        -       0      -     1  100%"* ]]
}

@test "a warning on stderr does not break the read" {
  HUB_WARN=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" warn
}
