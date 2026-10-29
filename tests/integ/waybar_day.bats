#!/usr/bin/env bats
# day.sh: the waybar day chip. The bar is today's merged PRs from day-log's record plus a
# red !N for what is red now. What these pin: no record reads -, never 0; a record hub:log
# stopped refreshing is dimmed with its age; Prometheus down still shows the merged count
# and says !? instead of a quiet nothing; PR titles with quotes and markup stay valid.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/day.sh"
  MERGE=$'\uf419' # nf-oct-git_merge, as an escape so no editor can strip it
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR"
  export DAYLOG_DIR="$FX/daylog" DAYLOG_NOW
  DAYLOG_NOW="$(date -d '2026-10-29 15:00' +%s)"
  mkdir -p "$DAYLOG_DIR"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/red.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
  red "watch deploy_drift" "runner wave"
  record
}

# red item ... -> Prometheus's answer to PROM_RED_NOW.
red() {
  python3 - "$FX/red.json" "$@" <<'PY'
import json, sys
res = [{"metric": {"item": i}, "value": [0, "1"]} for i in sys.argv[2:]]
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

# record [age-seconds] -> today's day-log record: 4 merged (3 Games, 1 Fleet tooling), 1 ask,
# 1 session needing you, main red in unity-core-playground, 2 open PRs.
record() {
  local f="$DAYLOG_DIR/2026-10-29.json"
  python3 - "$f" <<'PY'
import json, sys
pr = lambda repo, n, title, at, area: {"repo": repo, "number": n, "title": title, "merged_at": at, "area": area}
json.dump({
    "date": "2026-10-29",
    "merged": [
        pr("unity-core-playground", 1, "first", "2026-10-29T15:00:00Z", "Games"),
        pr("unity-core-playground", 2, 'fix "quoted" <b>&</b>', "2026-10-29T19:00:00Z", "Games"),
        pr("unity-core", 3, "third", "2026-10-29T17:00:00Z", "Games"),
        pr(".dotfiles", 4, "fourth", "2026-10-29T18:00:00Z", "Fleet tooling"),
    ],
    "waiting": {"asks": [{"id": "a"}], "needs": [{"who": "x"}], "main": [{"repo": "unity-core-playground"}]},
    "open": [{"number": 9}, {"number": 10}],
}, open(sys.argv[1], "w"))
PY
  touch -d "@$((DAYLOG_NOW - ${1:-120}))" "$f"
}

tip() { jq -r .tooltip <<< "$output"; }

@test "the bar is today's merged count, then red now as a red !N" {
  run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "$MERGE 4 <span color='#ef5734'>!2</span>"
  assert_equal "$(jq -r .class <<< "$output")" critical
}

@test "the hover groups merged PRs by area and repo, newest first, and says what waits" {
  run "$MODULE"
  run tip
  assert_line --index 1 "merged today: 4"
  assert_line --index 2 "by area: Games 3, Fleet tooling 1"
  assert_line --index 3 "by repo: unity-core-playground 2, .dotfiles 1, unity-core 1"
  assert_line --index 4 "  unity-core-playground#2 fix \"quoted\" &lt;b&gt;&amp;&lt;/b&gt;"
  assert_line --index 5 "  .dotfiles#4 fourth"
  assert_output --partial "waiting on you: 1 asks, 1 sessions need you, main red: unity-core-playground"
  assert_output --partial "open PRs: 2"
  assert_output --partial "record 2m old"
  assert_output --partial "red now (2): runner wave, watch deploy_drift"
}

@test "markup in a PR title still yields valid JSON and escaped Pango" {
  run "$MODULE"
  jq -e . <<< "$output" >/dev/null
  refute_output --partial "<b>&</b>"
}

@test "nothing red leaves the count plain and the class ok" {
  red
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "$MERGE 4"
  assert_equal "$(jq -r .class <<< "$output")" ok
  run tip
  assert_output --partial "red now: nothing"
}

@test "a record hub:log stopped refreshing is dimmed, with its age" {
  record 3600
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "<span color='#7f7f7f'>$MERGE 4</span> <span color='#ef5734'>!2</span>"
  run tip
  assert_output --partial "record 1h00m old, hub:log is not refreshing it"
}

# Negative control: no record is -, never a 0 nobody counted.
@test "no record for today reads -, never 0" {
  rm "$DAYLOG_DIR/2026-10-29.json"
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output")" "$MERGE - <span color='#ef5734'>!2</span>"
  run tip
  assert_output --partial "merged today: no record"
}

@test "Prometheus unreadable still shows the merged count and says !? in amber" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(jq -r .text <<< "$output")" "$MERGE 4 <span color='#ffcc2f'>!?</span>"
  assert_equal "$(jq -r .class <<< "$output")" warn
  run tip
  assert_output --partial "red now: cannot read http://prom.test"
}
