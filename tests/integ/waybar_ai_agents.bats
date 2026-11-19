#!/usr/bin/env bats
# ai_agents.sh: the waybar agents chip, the one overview of live agent sessions. The bar is the
# fleet total and three counts within it from fleet-sessions on Prometheus, ~ working in amber, a check mark ready (LANDED or DONE)
# in green and ! need you in red, after a robot coloured by fleet health; the hover has the stage counts, then a section per tmux world
# with its counts and a row, with its idle time and why, only for a session that needs you or is stalled (working, done, landed,
# chat and parked are counts, never rows; dashboards.md rule 3). What these pin: the bar is four numbers whatever the fleet's size (a
# group per project pushed the clock off the bar); the total is every session on every host,
# chat, stalled and parked included, so it reads as the whole fleet; sessions group by world, not repo; parked is
# listed and in the total only; a stalled session or a stale textfile turns the robot red, an unclear
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
  # bar <health colour> <total> <working> <ready> <need>: the chip text.
  bar() { printf "<span color='%s'>%s:</span>%s  <span color='$Y'>~:%s</span>  <span color='$G'>%s:%s</span>  %s" "$1" "$ICON" "$2" "$3" "$CK" "$4" "$(need "$5")"; }
  need() { if [ "$1" = 0 ]; then printf '!:0'; else printf "<span color='$R'>!:%s</span>" "$1"; fi; }
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" AGENTS_NOW=100000
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
}

# feed [target=BUCKET:age[:idle[:why]] ...] [mtime=<age s>|mtime=-] [dup:target=...] [p:<project>:target=...]
# -> Prometheus's answer: one agent_session_age_minutes series per session (idle adds
# agent_session_idle_minutes, and why adds agent_session_why), and fleet_sessions.prom written 60s ago unless mtime says otherwise.
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
    b, age, *idle = v.split(":", 3)
    base = {"target": k, "bucket": b, "project": proj, "host": "h1", "instance": inst}
    res.append({"metric": dict(base, __name__="agent_session_age_minutes"), "value": [0, age]})
    if idle:
        res.append({"metric": dict(base, __name__="agent_session_idle_minutes"), "value": [0, idle[0]]})
    if len(idle) > 1:
        res.append({"metric": dict(base, __name__="agent_session_why", reason=idle[1]), "value": [0, "1"]})
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
  assert_equal "$(text)" "$(bar "$G" 6 2 2 1)"
  assert_equal "$(class)" ok
  local args=() i
  for i in $(seq 1 40); do args+=("lab/uc-agent-1$i:1=WORKING:5"); done
  feed "${args[@]}"
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 40 40 0 0)"
}

@test "the hover groups by world, not repo, and lists only what wants you: working and done are counts" {
  feed hub/dotfiles:1=WORKING:30 hub/shepherd:2=NEEDS:90:20:"1 pending ask(s)" lab/dotfiles-agent-2:1=WORKING:5 \
    lab/uc-agent-1:1=WORKING:10 lab/uc-agent-2:1=DONE:400 lab/uc-agent-9:1=STALLED:200:80:"PR #7 CI red"
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Sessions</b>  6 total, 5 in progress: <span color='$Y'>1</span> need you, <span color='$Y'>1</span> stalled, 1 done, 3 working"
  assert_line --index 2 "<b>hub</b>  2 in progress: <span color='$Y'>1</span> need you, 1 working"
  assert_line --index 3 "<tt>NEEDS    shepherd:2   idle 20m    1 pending ask(s)</tt>"
  assert_line --index 4 "<b>lab</b>  3 in progress: <span color='$Y'>1</span> stalled, 1 done, 2 working"
  assert_line --index 5 "<tt><span color='$Y'>STALLED  uc-agent-9:1 idle 1h20m  PR #7 CI red</span></tt>"
  refute_output --partial "WORKING"
  refute_output --partial "DONE "
  refute_output --partial "uc-agent-1:1"
}

@test "a world with nothing waiting is its counts line alone" {
  feed lab/uc-agent-1:1=WORKING:10 lab/uc-agent-2:1=LANDED:300 lab/uc-agent-3:1=DONE:400
  run "$MODULE"
  run tip
  assert_line "<b>lab</b>  1 in progress: 1 done, 1 landed, 1 working"
  refute_output --partial "<tt>"
}

@test "a need-you or stalled row says why, and says so when no reason was published" {
  feed hub/a:1=NEEDS:30:12:"plan awaiting approval" hub/b:1=NEEDS:30:5
  run "$MODULE"
  run tip
  assert_output --partial "NEEDS    a:1      idle 12m    plan awaiting approval"
  assert_output --partial "NEEDS    b:1      idle 5m     no reason published"
}

@test "a reason with a colon or a markup character reaches the hover whole and escaped" {
  feed hub/a:1=NEEDS:30:12:"PR <#7>: CI red & stuck"
  run "$MODULE"
  run tip
  assert_output --partial "PR &lt;#7&gt;: CI red &amp; stuck"
}

@test "a stalled session turns the robot amber, leads the hover and heads its world" {
  feed lab/uc-agent-1:1=WORKING:10 lab/uc-agent-9:1=STALLED:200:80:"PR #9 conflicts"
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$Y" 2 1 0 0)"
  assert_equal "$(class)" warn
  run tip
  assert_line --index 1 "<span color='$Y'>1 session(s) STALLED: unlanded work and idle, or a ready PR that conflicts</span>"
  assert_line --index 2 "<b>lab</b>  2 in progress: <span color='$Y'>1</span> stalled, 1 working"
  assert_line --index 3 "<tt><span color='$Y'>STALLED  uc-agent-9:1 idle 1h20m  PR #9 conflicts</span></tt>"
}

@test "the hover's order is the published bucket order: a need-you line leads a stalled one" {
  feed lab/uc-agent-1:1=STALLED:200:80:x lab/uc-agent-2:1=NEEDS:30:20:y lab/uc-agent-3:1=WORKING:10
  run "$MODULE"
  run tip
  assert_output --partial "3 in progress: "
  assert_line --index 3 --partial "NEEDS "
  assert_line --index 3 --partial "uc-agent-2:1"
  assert_line --index 4 --partial "STALLED "
}

@test "no published bucket order reads amber and says so, never a built-in list" {
  feed lab/uc-agent-1:1=WORKING:10 novocab
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no agent_session_bucket on Prometheus"
}

@test "a CHAT session is counted, has no row and leaves the robot green: the human's conversation is not attention" {
  feed hub/dotfiles:1=CHAT:10
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 1 0 0 0)"
  assert_equal "$(class)" inactive
  run tip
  assert_output --partial "1 total, 0 in progress: 1 chat"
  refute_output --partial "<span color='$Y'>"
  refute_output --partial "<tt>"
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
  assert_equal "$(text)" "$(bar "$G" 1 1 0 0)"
}

@test "the total is the whole fleet: chat, stalled and parked sessions, a worker's too, are in it" {
  feed hub/dotfiles:1=WORKING:10 lab/uc-agent-1:1=NEEDS:20 lab/uc-agent-2:1=DONE:30 \
    lab/uc-agent-3:1=STALLED:200:80 razer@lab/dotfiles-agent-4:1=CHAT:300 \
    razer@lab/dotfiles-agent-5:1=CHAT:300 lab/uc-agent-6:1=PARKED:50
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$Y" 7 1 1 1)"
  run tip
  assert_line --index 0 --partial "<b>Sessions</b>  7 total, 3 in progress: "
}

@test "no sessions with a fresh textfile is inactive zeros" {
  feed
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 0 0 0 0)"
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
  assert_equal "$(text)" "$ICON:<span color='$Y'>?</span>"
  assert_equal "$(class)" warn
}

@test "a reason with a newline or a pipe stays one row" {
  feed hub/a:1=NEEDS:30:12:$'line one\nline | two' hub/b:1=NEEDS:30:5:"ok"
  run "$MODULE"
  run tip
  assert_output --partial "NEEDS    a:1 "
  assert_output --partial "line one line   two"
  assert_output --partial "idle 5m     ok"
}
