#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It renders `hub ci --json` .glance, the CI model hub-core
# computes for every CI surface. What these pin: the bar is `CI r:<running> q:<queued>` behind dim
# labels and nothing else; its class is ok whatever the glance alert or domain level says, since a
# runner or machine down is the health chip's; the hover is in figures, no meter cells: hub ci's red
# lines first (busy ARC runners with no pod series make every booking `?`), the Unity pool running of
# its max, the head with the booked CPU, the 1h and 5h windows, jobs by kind with no WEIGHT and no
# empty row, one row per machine with booked and used cores, memory and jobs, a red name only with
# its reason on the row, and under it the next job and what runs there in words; then GitHub's own
# runners, the stopped cloud hosts and the pods waiting for room, down and long runs, WAITING; and a
# failed hub read shows `CI: prom down`, never the last numbers.

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

# glance <jq patch>: a warn domain with an ok alert and 3 of 3 runners up, 2 jobs running, 2 queued; ms-a2 the one CI node,
# its job pods booking 4.38 of 32 cores and 2.5G of 92G with 6.4 cores really used and two jobs of one PR; the workstation's
# Unity slot on no CI node; mac-mini idle with a job that fits it; every pod placed; one stopped cloud host, nothing
# hosted, no Unity pool or windows read, no pod waiting for room, nothing WAITING, then the patch merged over it.
glance() {
  jq -n --argjson patch "$1" '{glance: ({
    level: "warn", alert: "ok", up: 3, expected: 3, parts: [{name: "pools", level: "warn"}, {name: "watches", level: "ok"}],
    feed: null, busy: 2, queued: 2, oldest: 900, done: 4, pass: 0.75, unplaced: 0, unity: null, windows: [], hosted: [],
    booked: {cpu: 4.38, reserved: 0, cpu_alloc: 32, mem: 2700000000, mem_alloc: 98768805888}, pending: [],
    kinds: [{kind: "unity", running: 2, waiting: 2, oldest: 900, done: 2, usual: 1260, pass: 0.5},
            {kind: "github-hosted", running: null, waiting: null, oldest: null, done: 2, usual: null, pass: 1}],
    machines: [{host: "ms-a2", state: "up", busy: 2, cpu: 0.2, used: 6.4, load: 0.2, next: null,
                booked: {cpu: 4.38, reserved: 0, cpu_alloc: 32, mem: 2700000000, mem_alloc: 98768805888},
                work: [{set: "arc-repo-dotfiles", repo: ".dotfiles", pr: "3592", branch: "", job: "fast tier", unit: "unit", of: 24, n: 2, ran: 400, usual: 360}]},
               {host: "workstation", state: "up", busy: 1, cpu: 0.1, used: 2.5, load: 0.4, next: null, booked: null,
                work: [{set: "unity", repo: "platform", pr: "", branch: "main", job: "PlayMode", unit: "", of: null, n: 1, ran: 900, usual: 1260}]},
               {host: "mac-mini", state: "up", busy: 0, cpu: null, used: null, load: null, next: {job: "Checks", repo: "web", n: 1, wait: 300}, booked: null, work: []}],
    off: ["aws-burst-1"], down: [], long: [], next: []} * $patch)}' > "$FX/ci.json"
}

# machine <json>: one machine row, the rest of the fixture as glance gives it.
machine() { glance "{\"machines\": [$1]}"; }

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

@test "a machine row is booked and used cores, memory and jobs in figures, with no meter cell anywhere" {
  run "$MODULE"
  run plain
  assert_line "ms-a2        cpu 4.4/32 booked, 6.4 used  mem 2.5G/92G  2 jobs"
  # A machine on no CI node reads the cores it uses; one with no reading reads its jobs.
  assert_line "workstation  cpu 2.5 used  1 job"
  assert_line "mac-mini     0 jobs"
  refute_output --regexp '[▏▎▍▌▋▊▉█]'
  refute_output --partial "BOOKED"
  refute_output --partial "MACHINE"
}

@test "a reservation's cores are named in the booking" {
  machine '{"host": "tuf", "state": "up", "busy": 1, "used": 3, "load": 0.1, "next": null, "work": [],
    "booked": {"cpu": 9.4, "reserved": 7.4, "cpu_alloc": 16, "mem": 1073741824, "mem_alloc": 34359738368}}'
  run "$MODULE"
  run plain
  assert_line "tuf      cpu 9.4/16 booked (7.4 reserved), 3.0 used  mem 1.0G/32G  1 job"
}

@test "a node with pods but no allocatable read (its CI taint gone) books bare, never against 0" {
  machine '{"host": "ms-a2", "state": "up", "busy": 1, "used": null, "load": 0.2, "next": null, "work": [],
    "booked": {"cpu": 1.69, "reserved": 0, "cpu_alloc": 0, "mem": 1300000000, "mem_alloc": 0}}'
  run "$MODULE"
  run plain
  assert_line "ms-a2    cpu 1.7 booked  mem 1.2G  1 job"
  refute_output --partial "/0 "
}

@test "busy ARC runners with no pod series: the red line comes first and every booking is ?, never 0.0" {
  glance '{"alert": "red", "unplaced": 3}'
  jq '.red = ["pod series missing for 3 of 6 busy ARC runners: machines unplaced", "HD (game) needs [gpu]: no online runner holds gpu"]' "$FX/ci.json" > "$FX/x" && mv "$FX/x" "$FX/ci.json"
  run "$MODULE"
  assert_equal "$(tip | sed -n 2p)" "<span color='#ef5734'>pod series missing for 3 of 6 busy ARC runners: machines unplaced</span>"
  assert_equal "$(tip | sed -n 3p)" "<span color='#ef5734'>HD (game) needs [gpu]: no online runner holds gpu</span>"
  assert_equal "$(jq -r .class <<< "$output")" ok
  run plain
  assert_line "2 running, 2 queued (oldest 15m), booked ?/32 cpu"
  assert_line "ms-a2        cpu ?/32 booked, 6.4 used  mem ?/92G  2 jobs"
  refute_output --partial "4.4/32"
}

@test "with every pod placed there is no unplaced line and the booking is a figure" {
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2 running, 2 queued (oldest 15m), booked 4.4/32 cpu"
  run plain
  refute_output --partial "pod series missing"
  refute_output --partial "?/"
}

@test "the Unity line is jobs running of the pool's max, by group, under the title; none read is no line" {
  glance '{"unity": {"running": 3, "max": 18, "sets": [{"name": "build", "running": 1, "max": 7}, {"name": "test", "running": 2, "max": 11}]}}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "Unity  3 running of 18 max (build 1/7, test 2/11)"
  glance '{}'
  run "$MODULE"
  run plain
  refute_output --partial "Unity "
}

@test "the windows line is runs, pass and failed in 1h and 5h, the pass painted under 90%; the head has no 24h" {
  glance '{"windows": [{"span": "1h", "runs": 410, "failed": 3, "pass": 0.96}, {"span": "5h", "runs": 2050, "failed": 21, "pass": 0.88}]}'
  run "$MODULE"
  assert_equal "$(tip | sed -n 3p)" "1h: 410 runs, 96% pass, 3 failed  5h: 2,050 runs, <span color='#ffcc2f'>88% pass</span>, 21 failed"
  assert_equal "$(plain | sed -n 2p)" "2 running, 2 queued (oldest 15m), booked 4.4/32 cpu"
  run plain
  refute_output --partial "done 24h"
  glance '{"windows": [], "queued": 0, "booked": null}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2 running, 0 queued"
  assert_equal "$(plain | sed -n 3p)" "ci: pools warn, watches ok"
}

@test "what runs on a machine is one line per PR or branch and job, a matrix as n of N units" {
  machine '{"host": "ms-a2", "state": "up", "busy": 19, "used": 9.1, "load": 0.2, "booked": null,
    "next": {"job": "Checks", "repo": "web", "n": 1, "wait": 300},
    "work": [{"set": "arc-repo-dotfiles", "repo": ".dotfiles", "pr": "3592", "branch": "", "job": "fast tier", "unit": "unit", "of": 24, "n": 16, "ran": 400, "usual": 360},
             {"set": "arc-org-light", "repo": "web", "pr": "", "branch": "feat/a-very-long-branch-name-here", "job": "lint", "unit": "", "of": null, "n": 2, "ran": 40, "usual": null},
             {"set": "arc-unity-test", "repo": "game", "pr": "7", "branch": "", "job": "Tests shard", "unit": "", "of": 3, "n": 1, "ran": 75, "usual": 600}]}'
  run "$MODULE"
  run plain
  assert_line "  next: Checks (web) waited 5m"
  assert_line "  .dotfiles #3592 fast tier: 16 of 24 units, 6m (usual 6m) on arc-repo-dotfiles"
  assert_line "  web feat/a-very-long-branch~ lint: x2, 40s on arc-org-light"
  assert_line "  game #7 Tests shard: 1 of 3, 1m (usual 10m) on arc-unity-test"
  refute_output --partial "[arc-"
}

@test "GitHub's own runners are one line by repo; none running is no line" {
  glance '{"hosted": [{"repo": "web", "n": 3}, {"repo": "platform", "n": 1}]}'
  run "$MODULE"
  run plain
  assert_line "github-hosted: web 3, platform 1"
  glance '{}'
  run "$MODULE"
  run plain
  refute_output --partial "github-hosted:"
}

@test "a red machine name always says why on its row: hot past the load chip's HOT_RATIO, or a state that takes no job" {
  glance '{"machines": [
    {"host": "ms-a2", "state": "up", "busy": 4, "used": 20, "load": 1.5, "next": null, "work": [],
     "booked": {"cpu": 4.38, "reserved": 0, "cpu_alloc": 32, "mem": 2700000000, "mem_alloc": 98768805888}},
    {"host": "deskslim-1", "state": "quarantined", "busy": 0, "used": null, "load": 0.1, "next": null, "work": [], "booked": null},
    {"host": "razer", "state": "up", "busy": 1, "used": null, "load": 1.49, "next": null, "work": [], "booked": null},
    {"host": "mac-mini", "state": "up", "busy": 0, "used": null, "load": null, "next": null, "work": [], "booked": null}]}'
  run "$MODULE"
  [[ "$(tip)" == *$'\n<span color=\'#ef5734\'>ms-a2     </span>  cpu 4.4/32 booked, 20.0 used  mem 2.5G/92G  4 jobs  <span color=\'#ef5734\'>hot: load 1.5/core</span>\n'* ]]
  [[ "$(tip)" == *$'\n<span color=\'#ef5734\'>deskslim-1</span>  0 jobs  <span color=\'#ef5734\'>quarantined</span>\n'* ]]
  [[ "$(tip)" == *$'
razer       1 job\n'* ]]
  [[ "$(tip)" == *$'
mac-mini    0 jobs\n'* ]]
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
  assert_equal "$(tip | sed -n 2p)" "<span color='#ef5734'>Build desktop (game) needs [unity-build]: no online runner holds unity-build</span>"
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

@test "the parts line paints each level, and a short feed says why in red" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 3p)" "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
  glance '{"feed": "runner exporter missed its last scrape: runner rows may be missing"}'
  run "$MODULE"
  [[ "$(tip | sed -n 3p)" == *", <span color='#ef5734'>runner exporter missed its last scrape: runner rows may be missing</span>" ]]
}

@test "jobs by kind: running, waiting, oldest, done, usual and pass, no WEIGHT; none read is a dash" {
  run "$MODULE"
  run plain
  assert_line "KIND          RUNNING WAITING OLDEST  DONE USUAL  PASS"
  assert_line "unity               2       2    15m     2   21m  50%"
  assert_line "github-hosted       -       -      -     2     -  100%"
  assert_line "(done and pass: 24h)"
  refute_output --partial "WEIGHT"
  refute_output --partial "not measured yet"
}

@test "a kind with nothing running, waiting or done is no row, and with no kind left there is no table" {
  glance '{"kinds": [{"kind": "gates", "running": 0, "waiting": 0, "oldest": null, "done": 0, "usual": null, "pass": null},
                     {"kind": "light", "running": 1, "waiting": null, "oldest": null, "done": null, "usual": null, "pass": null}]}'
  run "$MODULE"
  run plain
  assert_line --regexp '^light +1 '
  refute_output --regexp '^gates'
  glance '{"kinds": [{"kind": "gates", "running": 0, "waiting": 0, "oldest": null, "done": 0, "usual": null, "pass": null}]}'
  run "$MODULE"
  run plain
  refute_output --partial "KIND"
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

@test "machine, kind and work names are escaped for pango after padding, so columns still line up" {
  glance '{"machines": [{"host": "a<b", "state": "up", "busy": 0, "used": null, "load": 0.2, "next": null, "booked": null,
             "work": [{"set": "s", "repo": "r&d", "pr": "1", "branch": "", "job": "x<y>", "unit": "", "of": null, "n": 1, "ran": 5, "usual": null}]}],
           "kinds": [{"kind": "x&y", "running": 0, "waiting": 0, "oldest": null, "done": 1, "usual": null, "pass": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *"a&lt;b      0 jobs"* ]]
  [[ "$(tip)" == *"  r&amp;d #1 x&lt;y&gt;, 5s on s"* ]]
  [[ "$(tip)" == *"x&amp;y        0       0      -     1     -  100%"* ]]
}

@test "a warning on stderr does not break the read" {
  HUB_WARN=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" ok
}
