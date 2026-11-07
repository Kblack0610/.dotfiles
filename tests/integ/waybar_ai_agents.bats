#!/usr/bin/env bats
# ai_agents.sh: the waybar agents chip, the one overview of live agent sessions. The bar is three
# totals from fleet-sessions on Prometheus, ~ working in amber, a check mark ready (LANDED or DONE)
# in green and ! need you in red, after a robot coloured by fleet health; the hover has the stage counts, then a section per tmux world
# with a line per session. What these pin: the bar is three totals whatever the fleet's size (a
# group per project pushed the clock off the bar); sessions group by world, not repo; parked is
# listed but counted nowhere; a stalled session or a stale textfile turns the robot red, an unclear
# one amber; a second scrape counts once; Prometheus down reads ? and no textfile reads amber,
# never a quiet 0.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ai_agents.sh"
  ICON=$'\U000f06a9' CK=$'\u2713' # as escapes so no editor can strip them
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  # bar <health colour> <working> <ready> <need>: the chip text.
  bar() { printf "<span color='%s'>%s</span> <span color='$Y'>~%s</span> <span color='$G'>%s%s</span> %s" "$1" "$ICON" "$2" "$CK" "$3" "$(need "$4")"; }
  need() { if [ "$1" = 0 ]; then printf '!0'; else printf "<span color='$R'>!%s</span>" "$1"; fi; }
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" AGENTS_NOW=100000
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
}

# feed [target=BUCKET:age[:idle] ...] [mtime=<age s>|mtime=-] [dup:target=...] [p:<project>:target=...]
# -> Prometheus's answer: one agent_session_age_minutes series per session (idle adds
# agent_session_idle_minutes), and fleet_sessions.prom written 60s ago unless mtime says otherwise.
# dup: is a second scrape; p: names the session's project, proj without it.
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
res, mtime = [], 60
for a in sys.argv[2:]:
    if a == "novocab":
        continue
    k, v = a.split("=", 1)
    if k == "mtime":
        mtime = None if v == "-" else int(v)
        continue
    inst, proj = "i1", "proj"
    if k.startswith("dup:"): inst, k = "i9", k[4:]
    if k.startswith("p:"): _, proj, k = k.split(":", 2)
    b, age, *idle = v.split(":")
    base = {"target": k, "bucket": b, "project": proj, "host": "h1", "instance": inst}
    res.append({"metric": dict(base, __name__="agent_session_age_minutes"), "value": [0, age]})
    if idle:
        res.append({"metric": dict(base, __name__="agent_session_idle_minutes"), "value": [0, idle[0]]})
if "novocab" not in sys.argv:
    for i, b in enumerate(["NEEDS", "STALLED", "DONE", "LANDED", "CHAT", "WORKING", "PARKED"]):
        for inst in ("i1", "i9"):
            res.append({"metric": {"__name__": "agent_session_bucket", "bucket": b, "host": "h1", "instance": inst,
                                   "finished": "1" if b in ("DONE", "LANDED") else "0",
                                   "in_progress": "1" if b in ("WORKING", "NEEDS", "STALLED") else "0"},
                        "value": [0, str(i)]})
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

@test "the bar is a green robot and amber working, green ready and red need-you totals, however many" {
  feed hub/dotfiles:1=WORKING:30 hub/dotfiles:2=NEEDS:90:20 lab/uc-agent-1:1=WORKING:10 \
    lab/uc-agent-2:1=LANDED:300 lab/uc-agent-3:1=DONE:400 lab/uc-agent-4:1=PARKED:50
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(bar "$G" 2 2 1)"
  assert_equal "$(class)" ok
  local args=() i
  for i in $(seq 1 40); do args+=("lab/uc-agent-1$i:1=WORKING:5"); done
  feed "${args[@]}"
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 40 0 0)"
}

@test "the hover groups by world, not repo: dotfiles in hub sits with hub, a lab dotfiles with lab" {
  feed hub/dotfiles:1=WORKING:30 hub/shepherd:2=NEEDS:90:20 lab/dotfiles-agent-2:1=WORKING:5 \
    lab/uc-agent-1:1=WORKING:10 lab/uc-agent-2:1=DONE:400
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Sessions</b>  4 in progress: <span color='$Y'>1</span> need you, 1 done, 3 working"
  assert_line --index 1 "<b>hub</b>  2 in progress: <span color='$Y'>1</span> need you, 1 working"
  assert_line --index 2 "<tt>NEEDS    shepherd:2         up 1h30m  idle 20m"
  assert_line --index 3 "WORKING  dotfiles:1         up 30m</tt>"
  assert_line --index 4 "<b>lab</b>  2 in progress: 1 done, 2 working"
  assert_line --index 5 "<tt>DONE     uc-agent-2:1       up 6h40m"
  assert_line --index 6 "WORKING  uc-agent-1:1       up 10m"
  assert_line --index 7 "WORKING  dotfiles-agent-2:1 up 5m</tt>"
}

@test "a stalled session turns the robot amber, leads the hover and heads its world" {
  feed lab/uc-agent-1:1=WORKING:10 lab/uc-agent-9:1=STALLED:200:80
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$Y" 1 0 0)"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 1 "<span color='$Y'>1 session(s) STALLED: unlanded work and idle, or a ready PR that conflicts</span>"
  assert_line --index 3 "<tt><span color='$Y'>STALLED  uc-agent-9:1 up 3h20m  idle 1h20m</span>"
}

@test "the hover's order is the published bucket order: a need-you line leads a stalled one" {
  feed lab/uc-agent-1:1=STALLED:200:80 lab/uc-agent-2:1=NEEDS:30:20 lab/uc-agent-3:1=WORKING:10
  run "$MODULE"
  run tip
  assert_output --partial "3 in progress: "
  assert_line --index 3 --partial "NEEDS "
  assert_line --index 4 --partial "STALLED "
  assert_line --index 5 --partial "WORKING "
}

@test "no published bucket order reads amber and says so, never a built-in list" {
  feed lab/uc-agent-1:1=WORKING:10 novocab
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no agent_session_bucket on Prometheus"
}

@test "a CHAT session is listed uncoloured and leaves the robot green: the human's conversation is not attention" {
  feed hub/dotfiles:1=CHAT:10
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 0 0 0)"
  assert_equal "$(class)" inactive
  run tip
  assert_output --partial "0 in progress: 1 chat"
  refute_output --partial "<span color='$Y'>"
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
  assert_equal "$(text)" "$(bar "$G" 1 0 0)"
}

@test "no sessions with a fresh textfile is inactive zeros" {
  feed
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 0 0 0)"
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
