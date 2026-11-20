#!/usr/bin/env bats
# ci_runners.sh: the waybar CI chip. It renders `hub ci --json` .glance, the slot model
# hub-core computes for every CI surface. What these pin: the bar is
# the governor's busy/capacity slot units, the queue and its drain time; its colour and class are the ci domain level, never its own
# judgement; the hover is a cell per slot on the title line, the board's head line, jobs by kind, one row per machine with a cell
# per slot and what its slots are doing (red past the load chip's HOT_RATIO), the stopped cloud hosts on one line, down and long
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

# glance <jq patch>: a warn glance, 2 busy of 3 slots plus 1 held (2/4), 2 queued, 4 done at
# 75%, 1.4 of 4 slot units busy and 2 units waiting that drain in 15m, one stopped cloud host,
# nothing NEXT, then the patch merged over it.
glance() {
  jq -n --argjson patch "$1" '{glance: ({
    level: "warn", parts: [{name: "pools", level: "warn"}, {name: "watches", level: "ok"}],
    feed: null, busy: 2, slots: 3, held: 1, total: 4, queued: 2, oldest: 900, done: 4, pass: 0.75,
    units_busy: 1.4, units: 4, backlog: 2, drain: 900,
    kinds: [{kind: "unity", busy: 2, slots: 3, held: 1, waiting: 2, oldest: 900, done: 2, pass: 0.5},
            {kind: "github-hosted", waiting: null, oldest: null, done: 2, pass: 1}],
    machines: [{host: "workstation", busy: 2, slots: 2, held: 1, why: "pinned", doing: "1 gates, 1 unity, 1 held: pinned", load: 0.4},
               {host: "mac-mini", busy: 0, slots: 1, held: 0, why: "-", doing: "1 free", load: null}],
    off: ["aws-burst-1"], down: [], long: [], next: []} * $patch)}' > "$FX/ci.json"
}

# The live shape the plan found (2026-11-18): 7 busy of 9 slots, 7 more held, 16 in all.
seven_held() {
  glance '{"busy": 7, "slots": 9, "held": 7, "total": 16, "units_busy": 6.4, "units": 16, "drain": 720, "machines": [
    {"host": "ms-a2", "busy": 4, "slots": 4, "held": 1, "why": "-", "doing": "4 unity, 1 held: -", "load": 0.2},
    {"host": "deskslim-2", "busy": 1, "slots": 1, "held": 2, "why": "cooldown", "doing": "1 unity, 2 held: cooldown", "load": 0.2},
    {"host": "windows-media-ci", "busy": 1, "slots": 2, "held": 2, "why": "pinned", "doing": "1 unity, 2 held: pinned, 1 free", "load": 0.2},
    {"host": "cachyos", "busy": 1, "slots": 2, "held": 2, "why": "pinned", "doing": "1 unity, 2 held: pinned, 1 free", "load": 0.2}]}'
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
  glance '{"level": "ok", "queued": 0, "busy": 0, "held": 0, "total": 3, "units_busy": 0, "units": 3}'
  run "$MODULE"
  assert_equal "$(bar)" "CI 0.0/3 q0"
  assert_equal "$(jq -r .class <<< "$output")" ok
}

@test "seven held slots: 16 cells in the hover, busy filled, held amber, free dim, and 6.4/16 units" {
  seven_held
  run "$MODULE"
  assert_equal "$(bar)" "<span color='#ffcc2f'>CI</span> 6.4/16 <span color='#ffcc2f'>q2</span> ~12m"
  assert_equal "$(tip | sed -n 1p | sed -E 's/<[^>]+>//g' | grep -o '▮' | wc -l)" 16
  assert_equal "$(plain | sed -n 2p)" "7/16 busy, 7 held, 2 queued (oldest 15m), 6.4/16 units, 2.0 units queued ~12m, 4 done 24h, 75% passed"
  # Each machine row draws its own cells like the chip: busy filled, held amber, free dim.
  [[ "$(tip)" == *"windows-media-ci   1/4  ▮<span color='#ffcc2f'>▮▮</span><span color='#7f7f7f'>▮</span>   1 unity"* ]]
  run plain
  assert_line "deskslim-2         1/3  ▮▮▮    1 unity, 2 held: cooldown"
  assert_line "ms-a2              4/5  ▮▮▮▮▮  4 unity, 1 held: -"
}

@test "the bar reads slot units, the queue and its drain time: CI 6.4/16 q9 ~12m (hc-668)" {
  glance '{"level": "ok", "queued": 9, "busy": 7, "slots": 9, "held": 7, "total": 16,
           "units_busy": 6.4, "units": 16, "backlog": 9.2, "drain": 720}'
  run "$MODULE"
  assert_equal "$(bar | sed -E 's/<[^>]+>//g')" "CI 6.4/16 q9 ~12m"
  assert_equal "$(plain | sed -n 2p)" "7/16 busy, 7 held, 9 queued (oldest 15m), 6.4/16 units, 9.2 units queued ~12m, 4 done 24h, 75% passed"
}

@test "with no governor unit series every unit field is a dash, never a made-up 0" {
  glance '{"units_busy": null, "units": null, "backlog": null, "drain": null}'
  run "$MODULE"
  assert_equal "$(bar | sed -E 's/<[^>]+>//g')" "CI -/- q2 -"
  assert_equal "$(plain | sed -n 2p)" "2/4 busy, 1 held, 2 queued (oldest 15m), -/- units, - units queued -, 4 done 24h, 75% passed"
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

@test "the head line is the board's, the pass rate painted amber under 90%" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 2p)" "2/4 busy, 1 held, 2 queued (oldest 15m), 1.4/4 units, 2.0 units queued ~15m, 4 done 24h, <span color='#ffcc2f'>75% passed</span>"
  glance '{"pass": 0.5}'
  run "$MODULE"
  [[ "$(tip | sed -n 2p)" == *"<span color='#ef5734'>50% passed</span>" ]]
  glance '{"queued": 0, "pass": 0.95}'
  run "$MODULE"
  assert_equal "$(plain | sed -n 2p)" "2/4 busy, 1 held, 0 queued, 1.4/4 units, 4 done 24h, 95% passed"
}

@test "the parts line paints each level, and a short feed says why in red" {
  run "$MODULE"
  assert_equal "$(tip | sed -n 3p)" "ci: pools <span color='#ffcc2f'>warn</span>, watches <span color='#a6e34a'>ok</span>"
  glance '{"feed": "runner exporter missed its last scrape: runner rows may be missing"}'
  run "$MODULE"
  [[ "$(tip | sed -n 3p)" == *", <span color='#ef5734'>runner exporter missed its last scrape: runner rows may be missing</span>" ]]
}

@test "jobs by kind: slots with the held ones, waiting, oldest, done and pass; none read is a dash" {
  run "$MODULE"
  run plain
  assert_line --index 3 "KIND          SLOTS       WAITING OLDEST  DONE  PASS"
  assert_line --index 4 "unity         2/3 +1 held       2    15m     2  50%"
  assert_line --index 5 "github-hosted -                 -      -     2  100%"
}

@test "a kind's lent slots show apart from its held ones, so held means idle on purpose" {
  glance '{"kinds": [{"kind": "unity", "busy": 2, "slots": 3, "held": 1, "lent": 2, "waiting": 0, "oldest": null, "done": 2, "pass": 0.5}]}'
  run "$MODULE"
  run plain
  assert_line --index 4 --partial "unity 2/3 +1 held +2 lent"
}

@test "one row per machine: busy/total, a cell per slot, what its slots do and why one is held; no SPACE, no WHERE, no pool names" {
  run "$MODULE"
  run plain
  assert_line "MACHINE      BUSY  SLOTS  DOING"
  assert_line "workstation   2/3  ▮▮▮    1 gates, 1 unity, 1 held: pinned"
  assert_line "mac-mini      0/1  ▮      1 free"
  assert_line "cloud: 1 host off"
  refute_output --partial "WHERE"
  refute_output --partial "SPACE"
  refute_output --partial "local:workstation"
  refute_output --partial "other"
}

@test "a machine at or past the load chip's HOT_RATIO has a red name and busy count; under it, or no reading, stays plain" {
  glance '{"machines": [
    {"host": "ms-a2", "busy": 4, "slots": 4, "held": 0, "doing": "4 unity", "load": 1.5},
    {"host": "razer", "busy": 1, "slots": 3, "held": 0, "doing": "1 unity, 2 free", "load": 1.49},
    {"host": "mac-mini", "busy": 0, "slots": 1, "held": 0, "doing": "1 free", "load": null}]}'
  run "$MODULE"
  [[ "$(tip)" == *"<span color='#ef5734'>ms-a2      4/4</span>  ▮▮▮▮   4 unity"* ]]
  [[ "$(tip)" == *$'\nrazer      1/3  ▮<span color=\'#7f7f7f\'>▮▮</span>    1 unity, 2 free\n'* ]]
  [[ "$(tip)" == *$'\nmac-mini   0/1  <span color=\'#7f7f7f\'>▮</span>      1 free'* ]]
}

@test "a machine with more slots than the header widens the SLOTS column for every row, DOING still lined up" {
  glance '{"machines": [
    {"host": "ms-a2", "busy": 4, "slots": 5, "held": 2, "doing": "4 unity, 2 held: lent, 1 free", "load": 0.2},
    {"host": "mac-mini", "busy": 0, "slots": 1, "held": 0, "doing": "1 free", "load": null}]}'
  run "$MODULE"
  run plain
  assert_line "MACHINE   BUSY  SLOTS    DOING"
  assert_line "ms-a2      4/7  ▮▮▮▮▮▮▮  4 unity, 2 held: lent, 1 free"
  assert_line "mac-mini   0/1  ▮        1 free"
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

@test "NEXT: each waiting group with where it fits and about when it starts, then where every runner is" {
  glance '{"next": [
    {"job": "Soak", "repo": "game", "n": 1, "wait": 3480, "stuck": false, "at": "razer", "starts": 1320, "can": [{"host": "razer", "state": "busy"}]},
    {"job": "Wide", "repo": "", "n": 2, "wait": 30, "stuck": false, "at": "aws", "starts": 0, "can": [{"host": "aws", "state": "idle"}]},
    {"job": "cron", "repo": "home-config", "n": 7, "wait": 960, "stuck": false, "at": "ms-a2", "starts": null, "can": [{"host": "ms-a2", "state": "seat"}]},
    {"job": "HD", "repo": "game", "n": 1, "wait": 100, "stuck": true, "at": "", "starts": null, "can": []}]}'
  run "$MODULE"
  run plain
  assert_line "NEXT                N WAITED  WHERE       STARTS"
  assert_line "Soak (game)         1    58m  razer       in 22m"
  assert_line "Wide                2    30s  aws         now"
  assert_line "cron (home-config)  7    16m  ms-a2 seat  -"
  assert_line "HD (game)           1     1m  nobody      -"
  assert_line "every runner: hub --tab 'infra ci', agent-web #infra/machines/&lt;host&gt;"
}

@test "nothing waiting draws no NEXT, still the every-runner line" {
  run "$MODULE"
  run plain
  refute_output --partial "NEXT"
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
  glance '{"machines": [{"host": "a<b", "busy": 0, "slots": 1, "doing": "1 free", "load": 0.2}],
           "kinds": [{"kind": "x&y", "waiting": 0, "oldest": null, "done": 1, "pass": 1}]}'
  run "$MODULE"
  [[ "$(tip)" == *"a&lt;b       0/1  <span color='#7f7f7f'>▮</span>      1 free"* ]]
  [[ "$(tip)" == *"x&amp;y  -           0      -     1  100%"* ]]
}

@test "a warning on stderr does not break the read" {
  HUB_WARN=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .class <<< "$output")" warn
}
