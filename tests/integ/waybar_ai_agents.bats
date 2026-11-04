#!/usr/bin/env bats
# ai_agents.sh: the waybar agents chip, the one overview of live agent sessions. The bar is three
# totals from fleet-sessions on Prometheus, ~ working, a check mark ready (LANDED or DONE) and
# ! need you, then a health dot; the hover has the stage counts, then a section per tmux world
# with a line per session. What these pin: the bar is three totals whatever the fleet's size (a
# group per project pushed the clock off the bar); sessions group by world, not repo; parked is
# listed but counted nowhere; a stalled session or a stale textfile turns the dot red, an unclear
# one amber; a second scrape counts once; Prometheus down reads ? and no textfile reads amber,
# never a quiet 0.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ai_agents.sh"
  ICON=$'\U000f06a9' CK=$'\u2713' DOT=$'\u25cf' # as escapes so no editor can strip them
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" AGENTS_NOW=100000
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
}

# feed [target=BUCKET:age[:idle] ...] [mtime=<age s>|mtime=-] [dup:target=...] -> Prometheus's
# answer: one agent_session_age_minutes series per session (idle adds agent_session_idle_minutes),
# and fleet_sessions.prom written 60s ago unless mtime says otherwise. dup: is a second scrape.
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
res, mtime = [], 60
for a in sys.argv[2:]:
    k, v = a.split("=", 1)
    if k == "mtime":
        mtime = None if v == "-" else int(v)
        continue
    inst = "i1"
    if k.startswith("dup:"): inst, k = "i9", k[4:]
    b, age, *idle = v.split(":")
    base = {"target": k, "bucket": b, "project": "proj", "host": "h1", "instance": inst}
    res.append({"metric": dict(base, __name__="agent_session_age_minutes"), "value": [0, age]})
    if idle:
        res.append({"metric": dict(base, __name__="agent_session_idle_minutes"), "value": [0, idle[0]]})
if mtime is not None:
    res.append({"metric": {"__name__": "node_textfile_mtime_seconds", "host": "h1",
                           "file": "/var/lib/node_exporter/textfile/fleet_sessions.prom"},
                "value": [0, str(100000 - mtime)]})
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }

@test "the bar is working, ready and need-you totals and a green dot, however many there are" {
  feed hub/dotfiles:1=WORKING:30 hub/dotfiles:2=NEEDS:90:20 lab/uc-agent-1:1=WORKING:10 \
    lab/uc-agent-2:1=LANDED:300 lab/uc-agent-3:1=DONE:400 lab/uc-agent-4:1=PARKED:50
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON ~2 ${CK}2 <span color='$Y'>!1</span> <span color='$G'>$DOT</span>"
  assert_equal "$(class)" ok
  local args=() i
  for i in $(seq 1 40); do args+=("lab/uc-agent-1$i:1=WORKING:5"); done
  feed "${args[@]}"
  run "$MODULE"
  assert_equal "$(text)" "$ICON ~40 ${CK}0 !0 <span color='$G'>$DOT</span>"
}

@test "the hover groups by world, not repo: dotfiles in hub sits with hub, a lab dotfiles with lab" {
  feed hub/dotfiles:1=WORKING:30 hub/shepherd:2=NEEDS:90:20 lab/dotfiles-agent-2:1=WORKING:5 \
    lab/uc-agent-1:1=WORKING:10 lab/uc-agent-2:1=DONE:400
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Sessions</b>  4 in progress: 3 working, <span color='$Y'>1</span> need you, 1 done"
  assert_line --index 1 "<b>hub</b>  2 in progress: 1 working, <span color='$Y'>1</span> need you"
  assert_line --index 2 "<tt>NEEDS    shepherd:2         up 1h30m  idle 20m"
  assert_line --index 3 "WORKING  dotfiles:1         up 30m</tt>"
  assert_line --index 4 "<b>lab</b>  2 in progress: 2 working, 1 done"
  assert_line --index 5 "<tt>WORKING  uc-agent-1:1       up 10m"
  assert_line --index 6 "WORKING  dotfiles-agent-2:1 up 5m"
  assert_line --index 7 "DONE     uc-agent-2:1       up 6h40m</tt>"
}

@test "a stalled session is red, leads the hover and heads its world" {
  feed lab/uc-agent-1:1=WORKING:10 lab/uc-agent-9:1=STALLED:200:80
  run "$MODULE"
  assert_equal "$(text)" "$ICON ~1 ${CK}0 !0 <span color='$R'>$DOT</span>"
  assert_equal "$(class)" critical
  run tip
  assert_line --index 1 "<span color='$R'>1 session(s) STALLED: unlanded work and idle, or a ready PR that conflicts</span>"
  assert_line --index 3 "<tt><span color='$R'>STALLED  uc-agent-9:1 up 3h20m  idle 1h20m</span>"
}

@test "an unclear session is amber" {
  feed hub/dotfiles:1=UNCLEAR:10
  run "$MODULE"
  assert_equal "$(text)" "$ICON ~0 ${CK}0 !0 <span color='$Y'>$DOT</span>"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "<span color='$Y'>1</span> unclear"
}

@test "a sessions textfile older than five minutes is red: the tick stopped" {
  feed hub/dotfiles:1=WORKING:10 mtime=900
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "fleet_sessions.prom on h1 is 15m old"
}

@test "a second scrape of a session counts once" {
  feed hub/dotfiles:1=WORKING:10 dup:hub/dotfiles:1=WORKING:10
  run "$MODULE"
  assert_equal "$(text)" "$ICON ~1 ${CK}0 !0 <span color='$G'>$DOT</span>"
}

@test "no sessions with a fresh textfile is inactive zeros" {
  feed
  run "$MODULE"
  assert_equal "$(text)" "$ICON ~0 ${CK}0 !0 <span color='$G'>$DOT</span>"
  assert_equal "$(class)" inactive
}

# Negative control: no textfile on Prometheus is a missing feed, never a quiet 0.
@test "no fleet_sessions.prom on Prometheus reads amber and says so" {
  feed mtime=-
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no fleet_sessions.prom on Prometheus"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  feed
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "$ICON <span color='$Y'>?</span>"
  assert_equal "$(class)" warn
}
