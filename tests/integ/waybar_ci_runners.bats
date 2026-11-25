#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It renders `hub ci --json` .glance, the slot model
# hub-core computes for every CI surface. What these pin: the bar is
# `CI r:<running> q:<queued>` behind dim labels and nothing else; its class is ok whatever the glance alert or domain level says, since a
# runner or machine down is the health chip's; the hover is each CI node's cells on the title line, the board's head line with the booked CPU, jobs by kind, one row per machine with
# the CPU and memory its job pods book and 4 cells of the fuller share (a part cell as an eighth block), what runs there and the next waiting job that fits it (red past the load chip's HOT_RATIO), the
# stopped cloud hosts and the pods waiting for room on a line each, down and long runs; and a failed hub read shows `CI: prom down`, never the last numbers.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ci_runners.sh"
  export FX="$BATS_TEST_TMPDIR" HUB="$BATS_TEST_TMPDIR/hub"
  # No palette file, so the labels are C_DIM whatever this clone generated.
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
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

# glance <jq patch>: a warn domain with an ok alert and 3 of 3 runners up, 2 jobs running, 2 queued, 4 done at 75%; ms-a2 the
# one CI node, its job pods booking 4.38 of 32 cores and 2.5G of 92G; the workstation's gate and Unity slot and mac-mini on no
# CI node; one stopped cloud host, no pod waiting for room, nothing WAITING, then the patch merged over it.
glance() {
  jq -n --argjson patch "$1" '{glance: ({
    level: "warn", alert: "ok", up: 3, expected: 3, parts: [{name: "pools", level: "warn"}, {name: "watches", level: "ok"}],
    feed: null, busy: 2, queued: 2, oldest: 900, done: 4, pass: 0.75,
    booked: {cpu: 4.38, cpu_alloc: 32, mem: 2700000000, mem_alloc: 98768805888}, pending: [],
    kinds: [{kind: "unity", running: 2, waiting: 2, oldest: 900, done: 2, pass: 0.5, weight: "1*"},
            {kind: "github-hosted", waiting: null, oldest: null, done: 2, pass: 1}],
    machines: [{host: "ms-a2", busy: 3, running: ["[arc-org-light] x2", "[forgejo-runner]"], next: null, load: 0.2,
                booked: {cpu: 4.38, cpu_alloc: 32, mem: 2700000000, mem_alloc: 98768805888}},
               {host: "workstation", busy: 2, running: ["[gates]", "[unity] platform"], next: null, load: 0.4, booked: null},
               {host: "mac-mini", busy: 0, running: [], next: {job: "Checks", repo: "web", n: 1, wait: 300}, load: null, booked: null}],
    off: ["aws-burst-1"], down: [], long: [], next: []} * $patch)}' > "$FX/ci.json"
}

# Three CI nodes as the cluster books them (2026-11-24): deskslim-1 near full on CPU, deskslim-2
# half full on memory with a Unity slot job in the same row, ms-a2 light; the workstation on no CI node.
cluster() {
  glance '{"machines": [
    {"host": "deskslim-1", "busy": 13, "running": ["[arc-org-light] x13"], "next": null, "load": 0.2,
     "booked": {"cpu": 22.5, "cpu_alloc": 24, "mem": 12884901888, "mem_alloc": 68719476736}},
    {"host": "deskslim-2", "busy": 3, "running": ["[unity] unity-core-playground x2", "[forgejo-runner]"], "next": null, "load": 0.2,
     "booked": {"cpu": 1, "cpu_alloc": 24, "mem": 34359738368, "mem_alloc": 68719476736}},
    {"host": "ms-a2", "busy": 3, "running": ["[arc-org-light] x2", "[forgejo-runner]"], "next": null, "load": 0.2,
     "booked": {"cpu": 4.38, "cpu_alloc": 32, "mem": 2700000000, "mem_alloc": 98768805888}},
    {"host": "workstation", "busy": 1, "running": ["[unity] platform"], "next": null, "load": 0.2, "booked": null}]}'
}

bar()  { jq -r .text <<< "$output"; }
bare() { bar | sed -E 's/<[^>]+>//g'; }
tip()  { jq -r .tooltip <<< "$output"; }
plain() { jq -r .tooltip <<< "$output" | sed -E 's/<[^>]+>//g'; }

@test "the bar is CI r:<running> q:<queued> behind dim labels, nothing else" {
  run "$MODULE"
  assert_success
  assert_equal "$(bar)" "<span color='#7f7f7f'>CI r:</span>2 <span color='#7f7f7f'>q:</span>2"
  assert_equal "$(jq -r .class <<< "$output")" ok
}

@test "an empty queue reads q:0" {
  glance '{"level": "ok", "queued": 0, "busy": 0}'
  run "$MODULE"
  assert_equal "$(bare)" "CI r:0 q:0"
  assert_equal "$(jq -r .class <<< "$output")" ok
}

@test "a CI node reads what its job pods book of its CPU and memory, and 4 cells of the fuller share, the part one on the dim colour" {
  cluster
  run "$MODULE"
  [[ "$(tip)" == *$'\ndeskslim-1  22.5/24 12G/64G  ███<span background=\'#7f7f7f\'>▊</span>  [arc-org-light] x13                                 -\n'* ]]
  # Memory is the fuller share on deskslim-2: half of it is two cells of four.
  [[ "$(tip)" == *$'\ndeskslim-2   1.0/24 32G/64G  ██<span color=\'#7f7f7f\'>██</span>  [unity] unity-core-playground x2, [forgejo-runner]  -\n'* ]]
  run plain
  assert_line "MACHINE              BOOKED        RUNNING                                             NEXT"
  assert_line "ms-a2       4.4/32 2.5G/92G  ▌███  [arc-org-light] x2, [forgejo-runner]                -"
  # A machine on no CI node has no cells and reads -; its Unity slot job is in the same row.
  assert_line "workstation               -        [unity] platform                                    -"
}

@test "the title is each CI node's cells, a group per node, so the cells read per machine" {
  cluster
  run "$MODULE"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>  ███<span background='#7f7f7f'>▊</span> ██<span color='#7f7f7f'>██</span> <span background='#7f7f7f'>▌</span><span color='#7f7f7f'>███</span>"
}

@test "a node with pods but no allocatable read (its CI taint gone) books bare, never against 0" {
  glance '{"machines": [{"host": "ms-a2", "busy": 1, "running": ["[arc-org-light]"], "next": null, "load": 0.2,
    "booked": {"cpu": 1.69, "cpu_alloc": 0, "mem": 1300000000, "mem_alloc": 0}}]}'
  run "$MODULE"
  [[ "$(plain)" == *"ms-a2"*"1.7 1.2G"*"[arc-org-light]"* ]]
  [[ "$(plain)" != *"/0 "* ]]
}

@test "a share rounds to the nearest eighth of a cell, and one that rounds up to 8 is a full cell" {
  glance '{"machines": [
    {"host": "a", "busy": 1, "running": ["x"], "next": null, "load": 0.2, "booked": {"cpu": 1, "cpu_alloc": 32, "mem": 0, "mem_alloc": 68719476736}},
    {"host": "b", "busy": 1, "running": ["x"], "next": null, "load": 0.2, "booked": {"cpu": 7.76, "cpu_alloc": 32, "mem": 0, "mem_alloc": 68719476736}}]}'
  run "$MODULE"
  [[ "$(tip)" == *$'\na       1.0/32 0B/64G  <span background=\'#7f7f7f\'>▏</span><span color=\'#7f7f7f\'>███</span>'* ]]
  [[ "$(tip)" == *$'\nb       7.8/32 0B/64G  █<span color=\'#7f7f7f\'>███</span>'* ]]
}

@test "the bar never shows the booking; the hover head does" {
  glance '{"level": "ok", "busy": 6, "queued": 9, "booked": {"cpu": 6.4, "cpu_alloc": 64, "mem": 0, "mem_alloc": 1}}'
  run "$MODULE"
  assert_equal "$(bare)" "CI r:6 q:9"
  assert_equal "$(plain | sed -n 2p)" "6 running, 9 queued (oldest 15m), booked 6.4/64 cpu, 4 done 24h, 75% passed"
}

@test "with no CI node reporting the booking is a dash and no cell is drawn, never a runner count as capacity" {
  glance '{"booked": null, "machines": [
    {"host": "workstation", "busy": 2, "running": ["[gates]", "[unity] platform"], "next": null, "load": 0.4, "booked": null}]}'
  run "$MODULE"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>"
  assert_equal "$(plain | sed -n 2p)" "2 running, 2 queued (oldest 15m), 4 done 24h, 75% passed"
  run plain
  assert_line "workstation      -        [gates], [unity] platform  -"
}

@test "job pods no node has room for are one amber line under the machines, by kind and size" {
  glance '{"pending": [{"kind": "arc-org-light", "n": 3, "cpu": 1.69, "mem": 1300000000}, {"kind": "forgejo-runner", "n": 1, "cpu": 1, "mem": 100000000}]}'
  run "$MODULE"
  [[ "$(tip)" == *"<span color='#ffcc2f'>waiting for room: arc-org-light x3 (1.69 cpu 1.2G each), forgejo-runner (1 cpu 95M)</span>"* ]]
  glance '{}'
  run "$MODULE"
  run plain
  refute_output --partial "waiting for room"
}

@test "a runner down or a job nobody can take leaves the bar plain and ok; the hover still names it" {
  glance '{"level": "red", "alert": "red", "up": 2, "expected": 3, "down": [{"host": "mac-mini", "state": "offline", "n": 1}]}'
  jq '.red = ["Build desktop (game) needs [unity-build]: no online runner holds unity-build"]' "$FX/ci.json" > "$FX/x" && mv "$FX/x" "$FX/ci.json"
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" ok
  assert_equal "$(bare)" "CI r:2 q:2"
  [[ "$(bar)" != *"#ef5734"* ]]
  assert_equal "$(tip | sed -n 4p)" "<span color='#ef5734'>Build desktop (game) needs [unity-build]: no online runner holds unity-build</span>"
  run plain
  assert_line "DOWN:"
  assert_line "  mac-mini  1 offline"
}

@test "no runner read still shows the counts and says no data in the hover" {
  glance '{"level": "nodata", "alert": "nodata", "up": 0, "expected": 0, "parts": []}'
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" ok
  assert_equal "$(bare)" "CI r:2 q:2"
  assert_equal "$(tip | sed -n 3p)" "ci: no data"
}

@test "the head line is the board's, the pass rate painted amber under 90%" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 2p)" "2 running, 2 queued (oldest 15m), booked 4.4/32 cpu, 4 done 24h, <span color='#ffcc2f'>75% passed</span>"
  glance '{"pass": 0.5}'
  run "$MODULE"
  [[ "$(tip | sed -n 2p)" == *"<span color='#ef5734'>50% passed</span>" ]]
  glance '{"queued": 0, "pass": 0.95}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2 running, 0 queued, booked 4.4/32 cpu, 4 done 24h, 95% passed"
}

@test "the parts line paints each level, and a short feed says why in red" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 3p)" "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
  glance '{"feed": "runner exporter missed its last scrape: runner rows may be missing"}'
  run "$MODULE"
  [[ "$(tip | sed -n 3p)" == *", <span color='#ef5734'>runner exporter missed its last scrape: runner rows may be missing</span>" ]]
}

@test "jobs by kind: weight, running, waiting, oldest, done and pass, no FREE; none read is a dash" {
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND          WEIGHT RUNNING WAITING OLDEST  DONE  PASS"
  assert_line --index 4 "unity             1*       2       2    15m     2  50%"
  assert_line --index 5 "github-hosted      -       -       -      -     2  100%"
  refute_output --partial "FREE"
}

@test "a kind the governor has not measured reads 1* under a key line; a measured one reads its share, and with none unmeasured there is no key" {
  run "$MODULE"
  run plain
  assert_line "* not measured yet, counted as a whole slot"
  glance '{"kinds": [{"kind": "light", "running": 1, "waiting": 0, "done": 5, "pass": 1, "weight": "0.66"}]}'
  run "$MODULE"
  run plain
  assert_line --regexp '^light +0\.66 '
  refute_output --partial "not measured yet"
}

@test "a kind reads its own jobs running, never the busy slots that carry its cap" {
  glance '{"kinds": [{"kind": "heavy", "running": 0, "busy": 7, "slots": 9, "waiting": 0, "oldest": null, "done": 2, "pass": 0.5}]}'
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND  WEIGHT RUNNING WAITING OLDEST  DONE  PASS"
  assert_line --index 4 --regexp '^heavy +- +0 +0 '
  refute_output --partial "7/9"
}

@test "one row per machine: BOOKED and its cells, RUNNING by kind and repo, NEXT the oldest waiting job that fits; no held, no SPACE, no WHERE, no slot counts" {
  run "$MODULE"
  [[ "$(tip)" == *$'\nms-a2       4.4/32 2.5G/92G  <span background=\'#7f7f7f\'>▌</span><span color=\'#7f7f7f\'>███</span>  [arc-org-light] x2, [forgejo-runner]  -\n'* ]]
  run plain
  assert_line "MACHINE              BOOKED        RUNNING                               NEXT"
  assert_line "workstation               -        [gates], [unity] platform             -"
  assert_line "mac-mini                  -        -                                     Checks (web) 5m"
  assert_line "cloud: 1 host off"
  refute_output --partial "held"
  refute_output --partial "WHERE"
  refute_output --partial "SPACE"
  refute_output --partial "local:workstation"
  refute_output --partial "other"
  refute_output --partial "DOING"
  refute_output --partial "SLOTS"
  refute_output --partial "TAKEN"
}

@test "a machine at or past the load chip's HOT_RATIO has a red name and booking; under it, or no reading, stays plain" {
  glance '{"machines": [
    {"host": "ms-a2", "busy": 4, "running": ["[arc-org-light] x4"], "next": null, "load": 1.5,
     "booked": {"cpu": 4.38, "cpu_alloc": 32, "mem": 2700000000, "mem_alloc": 98768805888}},
    {"host": "razer", "busy": 1, "running": ["[unity] platform"], "next": null, "load": 1.49, "booked": null},
    {"host": "mac-mini", "busy": 0, "running": [], "next": null, "load": null, "booked": null}]}'
  run "$MODULE"
  [[ "$(tip)" == *"<span color='#ef5734'>ms-a2    4.4/32 2.5G/92G</span>  <span background='#7f7f7f'>▌</span><span color='#7f7f7f'>███</span>  [arc-org-light] x4  -"* ]]
  [[ "$(tip)" == *$'\nrazer                  -        [unity] platform    -\n'* ]]
  [[ "$(tip)" == *$'\nmac-mini               -        -                   -'* ]]
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
  glance '{"machines": [{"host": "a<b", "busy": 0, "running": [], "next": null, "load": 0.2, "booked": null}],
           "kinds": [{"kind": "x&y", "waiting": 0, "oldest": null, "done": 1, "pass": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *"a&lt;b          -        -        -"* ]]
  [[ "$(tip)" == *"x&amp;y       -       -       0      -     1  100%"* ]]
}

@test "a warning on stderr does not break the read" {
  HUB_WARN=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" ok
}
