#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It renders `hub ci --json` .glance, the slot model
# hub-core computes for every CI surface. What these pin: the bar is
# `CI r:<running> q:<queued>` behind dim labels and nothing else; its class is ok whatever the glance alert or domain level says, since a
# runner or machine down is the health chip's; the hover is each CI node's cells on the title line, the board's head line with the units taken, jobs by kind, CI POOL as hub-core words it, one row per machine with
# the CPU and memory its pods take and 4 cells of the fuller share (a part cell as an eighth block) and the next waiting job that fits it (red past the load chip's HOT_RATIO), under it one line per
# run there in words, the 1h and 5h pass rates in the head, the unplaced ARC runners, the Unity pool and GitHub's own runners under the parts line, the pods waiting for room on a line, down and
# long runs; and a failed hub read shows `CI: prom down`, never the last numbers.

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
# one CI node, 32 units, its job pods taking 4.38 of them and 2.5G of 92G; the workstation's gate and Unity slot and mac-mini on no
# CI node; no pod waiting for room, nothing WAITING, then the patch merged over it.
glance() {
  jq -n --argjson patch "$1" '{glance: ({
    level: "warn", alert: "ok", up: 3, expected: 3, parts: [{name: "pools", level: "warn"}, {name: "watches", level: "ok"}],
    feed: null, busy: 2, queued: 2, oldest: 900, done: 4, pass: 0.75,
    units: {total: 32, taken: 4.38, free: 27.62, real: 8, brief: "taken 4.4/32 units (14%)", head: "CI POOL  32 units (1 unit = 1 CI core)", line: "taken 4.4 of 32 (14%), free 27.6, real use 8.0 (25%)", columns: ["TAKEN BY", "PODS", "EACH", "UNITS", "SHARE"], rows: [["arc-org-light", "2", "1.69", "3.4", "11%"], ["forgejo-runner", "1", "1.00", "1.0", "3%"], ["free", "", "", "27.6", "86%"]]},
    pending: [],
    kinds: [{kind: "unity", running: 2, waiting: 2, oldest: 900, done: 2, usual: 1260, pass: 0.5},
            {kind: "github-hosted", waiting: null, oldest: null, done: 2, pass: 1}],
    machines: [{host: "ms-a2", busy: 3, work: [{"set": "arc-org-light", "repo": "dotfiles", "pr": "3592", "job": "fast tier", "unit": "unit", "of": 24, "n": 2, "ran": 360, "usual": 300}, {"set": "forgejo-runner", "job": "build"}], next: null, load: 0.2,
                booked: {cpu: 4.38, cpu_alloc: 32, mem: 2700000000, mem_alloc: 98768805888}},
               {host: "workstation", busy: 2, work: [{"set": "gates", "repo": "dotfiles", "branch": "agent-9-261127-013802-ci-hover", "job": "gate", "n": 1, "ran": 120},
                                                {"set": "unity-build", "repo": "platform", "job": "Build iOS", "n": 1, "ran": 600, "usual": 540}], next: null, load: 0.4, booked: null},
               {host: "mac-mini", busy: 0, work: [], next: {job: "Checks", repo: "web", n: 1, wait: 300}, load: null, booked: null}],
    down: [], long: [], next: []} * $patch)}' > "$FX/ci.json"
}

# Three CI nodes as the cluster books them (2026-11-24): deskslim-1 near full on CPU, deskslim-2
# half full on memory with a Unity slot job in the same row, ms-a2 light; the workstation on no CI node.
cluster() {
  glance '{"machines": [
    {"host": "deskslim-1", "busy": 13, "work": [{"set": "arc-org-light", "repo": "dotfiles", "pr": "3592", "job": "fast tier", "unit": "unit", "of": 24, "n": 13, "ran": 360, "usual": 300}], "next": null, "load": 0.2,
     "booked": {"cpu": 22.5, "cpu_alloc": 24, "mem": 12884901888, "mem_alloc": 68719476736}},
    {"host": "deskslim-2", "busy": 3, "work": [{"set": "arc-unity-test", "repo": "unity-core-playground", "pr": "812", "job": "EditMode", "n": 2, "ran": 900, "usual": 1260},
                                         {"set": "forgejo-runner", "job": "build"}], "next": null, "load": 0.2,
     "booked": {"cpu": 1, "cpu_alloc": 24, "mem": 34359738368, "mem_alloc": 68719476736}},
    {"host": "ms-a2", "busy": 3, "work": [{"set": "arc-org-light", "repo": "dotfiles", "pr": "3592", "job": "fast tier", "unit": "unit", "of": 24, "n": 2, "ran": 360, "usual": 300}, {"set": "forgejo-runner", "job": "build"}], "next": null, "load": 0.2,
     "booked": {"cpu": 4.38, "cpu_alloc": 32, "mem": 2700000000, "mem_alloc": 98768805888}},
    {"host": "workstation", "busy": 1, "work": [{"set": "unity-build", "repo": "platform", "job": "Build iOS", "n": 1, "ran": 600}], "next": null, "load": 0.2, "booked": null}]}'
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
  [[ "$(tip)" == *$'\ndeskslim-1  22.5/24 12G/64G  ███<span background=\'#7f7f7f\'>▊</span>  -\n  dotfiles #3592 fast tier: 13 of 24 unit shards, 6m (usual 5m) on arc-org-light\n'* ]]
  # Memory is the fuller share on deskslim-2: half of it is two cells of four.
  [[ "$(tip)" == *$'\ndeskslim-2   1.0/24 32G/64G  ██<span color=\'#7f7f7f\'>██</span>  -\n  unity-core-playground #812 EditMode: x2, 15m (usual 21m) on arc-unity-test\n  build on forgejo-runner\n'* ]]
  run plain
  assert_line "MACHINE               TAKEN        NEXT"
  assert_line "ms-a2       4.4/32 2.5G/92G  ▌███  -"
  # A machine on no CI node has no cells and reads -; its Unity slot job is a line under it.
  assert_line "workstation               -        -"
  assert_line "  platform Build iOS, 10m on unity-build"
}

@test "the title is each CI node's cells, a group per node, so the cells read per machine" {
  cluster
  run "$MODULE"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>  ███<span background='#7f7f7f'>▊</span> ██<span color='#7f7f7f'>██</span> <span background='#7f7f7f'>▌</span><span color='#7f7f7f'>███</span>"
}

@test "a node with pods but no allocatable read (its CI taint gone) books bare, never against 0" {
  glance '{"machines": [{"host": "ms-a2", "busy": 1, "work": [{"set": "arc-org-light", "job": "lint"}], "next": null, "load": 0.2,
    "booked": {"cpu": 1.69, "cpu_alloc": 0, "mem": 1300000000, "mem_alloc": 0}}]}'
  run "$MODULE"
  [[ "$(plain)" == *"ms-a2"*"1.7 1.2G"*"lint on arc-org-light"* ]]
  [[ "$(plain)" != *"/0 "* ]]
}

@test "a share rounds to the nearest eighth of a cell, and one that rounds up to 8 is a full cell" {
  glance '{"machines": [
    {"host": "a", "busy": 1, "work": [{"job": "x"}], "next": null, "load": 0.2, "booked": {"cpu": 1, "cpu_alloc": 32, "mem": 0, "mem_alloc": 68719476736}},
    {"host": "b", "busy": 1, "work": [{"job": "x"}], "next": null, "load": 0.2, "booked": {"cpu": 7.76, "cpu_alloc": 32, "mem": 0, "mem_alloc": 68719476736}}]}'
  run "$MODULE"
  [[ "$(tip)" == *$'\na       1.0/32 0B/64G  <span background=\'#7f7f7f\'>▏</span><span color=\'#7f7f7f\'>███</span>'* ]]
  [[ "$(tip)" == *$'\nb       7.8/32 0B/64G  █<span color=\'#7f7f7f\'>███</span>'* ]]
}

@test "the bar never shows the units taken; the hover head does" {
  glance '{"level": "ok", "busy": 6, "queued": 9, "units": {"total": 64, "taken": 6.4, "brief": "taken 6.4/64 units (10%)"}}'
  run "$MODULE"
  assert_equal "$(bare)" "CI r:6 q:9"
  assert_equal "$(plain | sed -n 2p)" "6 running, 9 queued (oldest 15m), taken 6.4/64 units (10%), 4 done 24h, 75% passed"
}

@test "the hover head shows the 1h and 5h done counts before the 24h one, only once the kinds report them" {
  glance '{"done_1h": 0, "done_5h": 12}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2 running, 2 queued (oldest 15m), taken 4.4/32 units (14%), 0 done 1h, 12 done 5h, 4 done 24h, 75% passed"
}

@test "with no CI node reporting the units are gone and no cell is drawn, never a runner count as capacity" {
  glance '{"units": null, "machines": [
    {"host": "workstation", "busy": 2, "work": [{"set": "gates", "job": "gate"}], "next": null, "load": 0.4, "booked": null}]}'
  run "$MODULE"
  assert_equal "$(tip | sed -n 1p)" "<b>CI runners</b>"
  assert_equal "$(plain | sed -n 2p)" "2 running, 2 queued (oldest 15m), 4 done 24h, 75% passed"
  run plain
  refute_output --partial "CI POOL"
  assert_line "workstation      -        -"
  assert_line "  gate on gates"
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
  assert_equal "$(tip | sed -n 2p)" "2 running, 2 queued (oldest 15m), taken 4.4/32 units (14%), 4 done 24h, <span color='#ffcc2f'>75% passed</span>"
  glance '{"pass": 0.5}'
  run "$MODULE"
  [[ "$(tip | sed -n 2p)" == *"<span color='#ef5734'>50% passed</span>" ]]
  glance '{"queued": 0, "pass": 0.95}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2 running, 0 queued, taken 4.4/32 units (14%), 4 done 24h, 95% passed"
}

@test "the parts line paints each level, and a short feed says why in red" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 3p)" "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
  glance '{"feed": "runner exporter missed its last scrape: runner rows may be missing"}'
  run "$MODULE"
  [[ "$(tip | sed -n 3p)" == *", <span color='#ef5734'>runner exporter missed its last scrape: runner rows may be missing</span>" ]]
}

@test "jobs by kind: running, waiting, oldest, done, usual and pass, no FREE and no WEIGHT; none read is a dash" {
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND          RUNNING WAITING OLDEST  DONE USUAL  PASS"
  assert_line --index 4 "unity               2       2    15m     2   21m  50%"
  assert_line --index 5 "github-hosted       -       -      -     2     -  100%"
  refute_output --partial "FREE"
  refute_output --partial "not measured yet"
}

@test "CI POOL sits above the machines: its head and line, then TAKEN BY as hub-core words it, the first column left, the rest right, free last" {
  glance '{"units": {"rows": [["ci-build-slot", "2", "7.36", "14.7", "23%"], ["arc-org-light", "2", "1.69", "3.4", "5%"], ["other", "-", "-", "3.0", "5%"], ["free", "", "", "40.9", "64%"]]}}'
  run "$MODULE"
  run plain
  assert_line "CI POOL  32 units (1 unit = 1 CI core)"
  assert_line "taken 4.4 of 32 (14%), free 27.6, real use 8.0 (25%)"
  assert_line "TAKEN BY       PODS  EACH  UNITS  SHARE"
  assert_line "ci-build-slot     2  7.36   14.7    23%"
  assert_line "other             -     -    3.0     5%"
  assert_line "free                        40.9    64%"
  # The pool comes after the kinds and right before the MACHINE header, a blank line between.
  [[ "$output" == *$'free                        40.9    64%\n\nMACHINE'* ]]
}

@test "a kind reads its own jobs running, never the busy slots that carry its cap" {
  glance '{"kinds": [{"kind": "heavy", "running": 0, "busy": 7, "slots": 9, "waiting": 0, "oldest": null, "done": 2, "pass": 0.5}]}'
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND  RUNNING WAITING OLDEST  DONE USUAL  PASS"
  assert_line --index 4 --regexp '^heavy +0 +0 '
  refute_output --partial "7/9"
}

@test "one row per machine: TAKEN and its cells, NEXT the oldest waiting job that fits; no held, no SPACE, no WHERE, no slot counts" {
  run "$MODULE"
  [[ "$(tip)" == *$'\nms-a2       4.4/32 2.5G/92G  <span background=\'#7f7f7f\'>▌</span><span color=\'#7f7f7f\'>███</span>  -\n'* ]]
  run plain
  assert_line "MACHINE               TAKEN        NEXT"
  assert_line "workstation               -        -"
  assert_line "mac-mini                  -        Checks (web) 5m"
  refute_output --partial "RUNNING  "
  refute_output --partial "held"
  refute_output --partial "WHERE"
  refute_output --partial "SPACE"
  refute_output --partial "local:workstation"
  refute_output --partial "DOING"
  refute_output --partial "SLOTS"
}

@test "under each machine one line per run: repo and PR or else its branch cut to 24, the job, a matrix's shards, its time and usual, its scale set" {
  run "$MODULE"
  run plain
  assert_line "  dotfiles #3592 fast tier: 2 of 24 unit shards, 6m (usual 5m) on arc-org-light"
  assert_line "  build on forgejo-runner"
  assert_line "  dotfiles agent-9-261127-013802-c~ gate, 2m on gates"
  assert_line "  platform Build iOS, 10m (usual 9m) on unity-build"
  # A matrix with no word reads bare shards, and a run with no repo starts at its job.
  glance '{"machines": [{"host": "ms-a2", "busy": 3, "work": [{"set": "arc-org-light", "job": "Tests shard", "of": 3, "n": 3}], "next": null, "load": 0.2, "booked": null}]}'
  run "$MODULE"
  run plain
  assert_line "  Tests shard: 3 of 3 shards on arc-org-light"
  # A runner that names no job reads its repo and count, never a trailing space.
  glance '{"machines": [{"host": "ms-a2", "busy": 2, "work": [{"set": "arc-repo-dotfiles", "repo": "(not watched)", "job": "", "n": 2}], "next": null, "load": 0.2, "booked": null}]}'
  run "$MODULE"
  run plain
  assert_line "  (not watched): x2 on arc-repo-dotfiles"
}

@test "the head carries each window's pass rate beside its count, painted like the 24h one, and none with no rate" {
  glance '{"done_1h": 4, "pass_1h": 0.5, "done_5h": 12, "pass_5h": 0.95}'
  run "$MODULE"
  assert_equal "$(tip | sed -n 2p)" "2 running, 2 queued (oldest 15m), taken 4.4/32 units (14%), 4 done 1h (<span color='#ef5734'>50% passed</span>), 12 done 5h (95% passed), 4 done 24h, <span color='#ffcc2f'>75% passed</span>"
  glance '{"done_1h": 0, "done_5h": 12, "pass_5h": 0.8}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2 running, 2 queued (oldest 15m), taken 4.4/32 units (14%), 0 done 1h, 12 done 5h (80% passed), 4 done 24h, 75% passed"
}

@test "busy ARC runners with no pod series are one amber line under the parts, and the bar stays ok" {
  glance '{"unplaced": 3}'
  run "$MODULE"
  assert_equal "$(jq -r .class <<< "$output")" ok
  assert_equal "$(tip | sed -n 4p)" "<span color='#ffcc2f'>pod series missing for 3 busy ARC runners: on no machine row or unit</span>"
  glance '{"unplaced": 1}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 4p)" "pod series missing for 1 busy ARC runner: on no machine row or unit"
  glance '{"unplaced": 0}'
  run "$MODULE"
  run plain
  refute_output --partial "pod series missing"
}

@test "the Unity pool is one line of jobs running of its most, each set as hub-core sums it, and none with no pool" {
  glance '{"unity": {"running": 3, "max": 18, "sets": [{"name": "arc-unity-test", "running": 2, "max": 11}, {"name": "unity-build", "running": 1, "max": 7}]}}'
  run "$MODULE"
  run plain
  assert_line "Unity 3 running of 18 max (arc-unity-test 2/11, unity-build 1/7)"
  glance '{"unity": null}'
  run "$MODULE"
  run plain
  refute_output --partial "Unity "
}

@test "GitHub's own runners are one line by repo, escaped, and none when nothing runs there" {
  glance '{"hosted": [{"repo": "web", "n": 3}, {"repo": "pl<a", "n": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *$'\ngithub-hosted: web 3, pl&lt;a 1\n'* ]]
  glance '{"hosted": []}'
  run "$MODULE"
  run plain
  refute_output --partial "github-hosted:"
}

@test "a machine at or past the load chip's HOT_RATIO has a red name and booking; under it, or no reading, stays plain" {
  glance '{"machines": [
    {"host": "ms-a2", "busy": 4, "work": [{"set": "arc-org-light", "job": "lint", "n": 4}], "next": null, "load": 1.5,
     "booked": {"cpu": 4.38, "cpu_alloc": 32, "mem": 2700000000, "mem_alloc": 98768805888}},
    {"host": "razer", "busy": 1, "work": [{"set": "unity-build", "repo": "platform", "job": "Build iOS"}], "next": null, "load": 1.49, "booked": null},
    {"host": "mac-mini", "busy": 0, "work": [], "next": null, "load": null, "booked": null}]}'
  run "$MODULE"
  [[ "$(tip)" == *"<span color='#ef5734'>ms-a2    4.4/32 2.5G/92G</span>  <span background='#7f7f7f'>▌</span><span color='#7f7f7f'>███</span>  -"* ]]
  [[ "$(tip)" == *$'\nrazer                  -        -\n'* ]]
  [[ "$(tip)" == *$'\nmac-mini               -        -\n'* ]]
}

@test "a down runner host is listed under DOWN" {
  glance '{"down": [{"host": "windows-media", "state": "offline", "n": 1}]}'
  run "$MODULE"
  run plain
  assert_line "DOWN:"
  assert_line "  windows-media  1 offline"
}

@test "nothing down draws no DOWN line" {
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
  glance '{"machines": [{"host": "a<b", "busy": 0, "work": [{"repo": "x<y", "job": "a&b"}], "next": null, "load": 0.2, "booked": null}],
           "kinds": [{"kind": "x&y", "waiting": 0, "oldest": null, "done": 1, "pass": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *$'\na&lt;b          -        -\n  x&lt;y a&amp;b\n'* ]]
  [[ "$(tip)" == *"x&amp;y        -       0      -     1     -  100%"* ]]
}

@test "a warning on stderr does not break the read" {
  HUB_WARN=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" ok
}
