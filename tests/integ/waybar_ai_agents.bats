#!/usr/bin/env bats
# ai_agents.sh: the waybar agents chip, the one overview of live agent sessions. The bar is the fleet
# total and three counts from fleet-sessions on Prometheus (~ working amber, a check mark ready green,
# ! need you red) after a robot coloured by fleet health. The hover opens with one sentence (need you,
# stuck, working, as of when, on how many hosts), then any warning, then Need you, Stuck and Working
# sections from the summary/bar topic (`hub bar --json`), each row named by project and task, filled to
# the bar channel's line cap in that order, a line counting what was cut, and one for what is ready to
# close. What these pin: the bar is four numbers whatever the fleet's size; counts come from Prometheus
# and names from summary/bar; a missing or old topic is one amber line with the counts still shown; a
# stale textfile never counts its sessions and is named once (red only when every file is stale); the
# hover fits the bar channel and comms-lint fails one that does not.

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/ai_agents.sh"
  ICON=$'\U000f06a9' CK=$'✓' # as escapes so no editor can strip them
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  # bar <health colour> <total> <working> <ready> <need>: the chip text.
  bar() { printf "<span color='%s'>%s</span> %s  <span color='$Y'>~:%s</span>  <span color='$G'>%s:%s</span>  %s" "$1" "$ICON" "$2" "$3" "$CK" "$4" "$(need "$5")"; }
  need() { if [ "$1" = 0 ]; then printf '!:0'; else printf "<span color='$R'>!:%s</span>" "$1"; fi; }
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" AGENTS_NOW=100000 TZ=UTC
  export AGENT_MQTT_HOST=mqtt.test MQTT_SUB_FIXTURE="$BATS_TEST_TMPDIR/bar.json"
  export COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
printf '%s\n' "$*" >> "$FX/curl.args"
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
}

# feed [target=BUCKET:age[:idle] ...] [mtime=<age s>|mtime=-] [stale=<age s>] [dup:target=...] [novocab]
# -> Prometheus's answer: one agent_session_age_minutes series per session (idle adds
# agent_session_idle_minutes with the same labels), the bucket order, and fleet_sessions.prom written
# 60s ago unless mtime says otherwise. dup: is a second scrape. stale= adds a second, host-less
# fleet_sessions.prom of that age on another instance (the leftover on razer-laptop), with no sessions
# of its own: Prometheus's `and on (instance)` leaves them out.
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
    if k == "stale":
        res.append({"metric": {"__name__": "node_textfile_mtime_seconds", "instance": "10.0.0.9:9100",
                               "file": "/var/lib/node-exporter-textfile/fleet_sessions.prom"},
                    "value": [0, str(100000 - int(v))]})
        continue
    inst = "i1"
    if k.startswith("dup:"): inst, k = "i9", k[4:]
    b, age, *idle = v.split(":", 2)
    base = {"target": k, "bucket": b, "project": "proj", "host": "h1", "instance": inst}
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

# barfeed [age=<s>] [err=<text>] ['BUCKET|project|task|why|idle|target' ...] -> the retained
# summary/bar message, `hub bar --json` built <age> seconds ago (60 by default), sessions in the order
# given (hub-core sorts them). why is the reason, or the activity of a WORKING row; an empty idle is
# null. `barfeed -` leaves no message on the broker.
barfeed() {
  python3 - "$MQTT_SUB_FIXTURE" "$@" <<'PY'
import json, os, sys
path, args = sys.argv[1], sys.argv[2:]
if args == ["-"]:
    os.path.exists(path) and os.remove(path)
    sys.exit()
doc = {"as_of": 100000 - 60, "sessions": [], "ready": {"total": 0, "urgent": 0, "high": 0, "items": []},
       "candidates": [], "drain": None, "errors": []}
for a in args:
    if a.startswith("age="): doc["as_of"] = 100000 - int(a[4:]); continue
    if a.startswith("err="): doc["errors"].append(a[4:]); continue
    b, proj, task, why, idle, target = a.split("|")
    doc["sessions"].append({"bucket": b, "project": proj, "task": task,
        "reason": "" if b == "WORKING" else why, "activity": why if b == "WORKING" else "idle",
        "target": target, "item": "", "pr": None, "pr_state": "", "ci": "",
        "idle_min": int(idle) if idle else None, "done": b in ("DONE", "LANDED")})
json.dump(doc, open(path, "w"))
PY
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }
# plain: the hover as the human reads it, markup dropped and entities undone (pango_ansi, NO_COLOR).
plain() { jq -r .tooltip <<< "$output" | (. "$REPO_ROOT/.config/waybar/pango.sh"; NO_COLOR=1 pango_ansi); }

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

@test "the hover opens with need you, stuck and working from Prometheus, then a section per stage named by task" {
  feed hub/dotfiles:1=WORKING:30:3 hub/dotfiles:2=NEEDS:90:20 lab/uc-agent-1:1=WORKING:10:4 \
    lab/uc-agent-2:1=DONE:400 lab/uc-agent-9:1=STALLED:200:80 razer@lab/dotfiles-agent-4:1=CHAT:300
  barfeed 'NEEDS|dotfiles|retire the CI governor|1 pending ask(s)|20|hub/dotfiles:2' \
    'STALLED|playground|chip art pass|PR #3076 CI red|80|razer-laptop@lab/unity-core-playground-agent-12:1' \
    'WORKING|dotfiles|one export for hub cards|Bash: run bats tests|3|hub/dotfiles:1' \
    'WORKING|playground|move SaveWrites|testing|4|lab/uc-agent-1:1' \
    'DONE|playground|chain wiring||400|lab/uc-agent-2:1' 'CHAT|dotfiles|chat||300|razer@lab/dotfiles-agent-4:1'
  run "$MODULE"
  assert_success
  run tip
  assert_output "<b>Sessions:</b> <span color='$R'>1 need you</span>, <span color='$Y'>1 stuck</span>, 2 working. As of 03:45, 6 sessions on 3 hosts.

<b><span color='$R'>Need you</span></b>  1
<tt>  dotfiles    retire the CI governor                            1 pending ask(s)      20m     hub/dotfiles:2</tt>

<b><span color='$Y'>Stuck</span></b>  1
<tt>  playground  chip art pass                                     PR #3076 CI red       1h20m   ...ore-playground-agent-12</tt>

<b>Working</b>  2
<tt>  dotfiles    one export for hub cards                          Bash: run bats tests  3m
  playground  move SaveWrites                                   testing               4m</tt>

Ready to close 1 (1 done); also 1 chat"
}

@test "rows fill to the bar channel's line cap, need-you and stuck first, and a last line counts what was cut" {
  printf '[channel.bar]\nmax_lines = 12\nmax_line = 120\n' > "$BATS_TEST_TMPDIR/channels.toml"
  local rows=() args=() i
  for i in $(seq 1 20); do rows+=("WORKING|dotfiles|task w$i|busy|$i|hub/w$i:1"); args+=("hub/w$i:1=WORKING:5"); done
  rows+=("NEEDS|dotfiles|task n1|ask|9|lab/n1:1" "NEEDS|dotfiles|task n2|ask|8|lab/n2:1" "STALLED|dotfiles|task s1|conflict|90|lab/s1:1")
  feed "${args[@]}" lab/n1:1=NEEDS:30 lab/n2:1=NEEDS:30 lab/s1:1=STALLED:90
  barfeed "${rows[@]}"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/channels.toml" run "$MODULE"
  run tip
  # bats drops blank lines from $lines; the cap counts them, as the tooltip draws them
  assert_equal "$(printf '%s\n' "$output" | wc -l)" 12
  assert_output --partial "task n1"
  assert_output --partial "task n2"
  assert_output --partial "task s1"
  assert_output --partial "task w1 "
  refute_output --partial "task w2 "
  assert_line "+19 more working: click for every session (agent-panel)"
}

@test "a stage cut to no rows keeps its heading and count, and the cut line names each stage" {
  printf '[channel.bar]\nmax_lines = 8\nmax_line = 120\n' > "$BATS_TEST_TMPDIR/channels.toml"
  local rows=() i
  for i in $(seq 1 5); do rows+=("NEEDS|dotfiles|need $i|ask|$i|lab/n$i:1"); done
  rows+=("WORKING|dotfiles|work 1|busy|1|hub/w1:1")
  feed lab/n1:1=NEEDS:30 hub/w1:1=WORKING:5
  barfeed "${rows[@]}"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/channels.toml" run "$MODULE"
  run tip
  assert_line "<b>Working</b>  1"
  refute_output --partial "work 1"
  assert_line "+3 more need you, 1 more working: click for every session (agent-panel)"
}

@test "no summary/bar is one amber line, and the counts still show" {
  feed hub/dotfiles:2=NEEDS:90:20 lab/uc-agent-1:1=WORKING:10
  barfeed -
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 2 1 0 1)"
  run tip
  assert_output "<b>Sessions:</b> <span color='$R'>1 need you</span>, 0 stuck, 1 working. 2 sessions in all.
<span color='$Y'>No session detail: no summary/bar on mqtt.test</span>"
}

@test "an old summary/bar says how old in amber and lists no rows from it" {
  feed hub/dotfiles:2=NEEDS:90:20
  barfeed age=900 'NEEDS|dotfiles|stale task|ask|20|hub/dotfiles:2'
  run "$MODULE"
  run tip
  assert_line --index 1 --partial "<span color='$Y'>No session detail: summary/bar is 15m old"
  refute_output --partial "stale task"
}

# Negative control for the read: the same message fresh lists its row.
@test "a fresh summary/bar is read from the broker agent-mqtt-publish uses" {
  feed hub/dotfiles:2=NEEDS:90:20
  barfeed 'NEEDS|dotfiles|fresh task|ask|20|hub/dotfiles:2'
  run "$MODULE"
  run tip
  assert_output --partial "fresh task"
  refute_output --partial "No session detail"
  assert_equal "$(cat "$MQTT_SUB_FIXTURE.args")" "-h mqtt.test -p 1883 -t agents/+/summary/bar -W 1"
}

# A former lease holder that is switched off keeps its retained copy, and the broker may send it first.
@test "of every retained copy the newest as_of wins, whichever arrives first" {
  feed hub/dotfiles:2=NEEDS:90:20
  barfeed 'NEEDS|dotfiles|fresh task|ask|20|hub/dotfiles:2'
  local fresh; fresh="$(cat "$MQTT_SUB_FIXTURE")"
  barfeed age=259200 'NEEDS|dotfiles|old holder task|ask|20|hub/dotfiles:2'
  printf '\nnot json\n%s\n' "$fresh" >> "$MQTT_SUB_FIXTURE"
  run "$MODULE"
  run tip
  assert_output --partial "fresh task"
  refute_output --partial "old holder task"
  refute_output --partial "No session detail"
}

@test "a broker it cannot reach is said as such, not as a missing topic" {
  feed hub/dotfiles:2=NEEDS:90:20
  barfeed -
  MQTT_SUB_RC=1 run "$MODULE"
  run tip
  assert_line --index 1 "<span color='$Y'>No session detail: cannot reach the broker mqtt.test:1883</span>"
  refute_output --partial "no summary/bar"
}

@test "a source summary/bar could not read is an amber line beside the rows it has" {
  feed hub/dotfiles:2=NEEDS:90:20
  barfeed 'err=agent-queue list: timed out' 'NEEDS|dotfiles|a task|ask|20|hub/dotfiles:2'
  run "$MODULE"
  run tip
  assert_line --index 1 "<span color='$Y'>Session detail incomplete: agent-queue list: timed out</span>"
  assert_output --partial "a task"
}

@test "a task with markup, a newline or a non-ASCII character stays one escaped ASCII row" {
  feed hub/a:1=NEEDS:30:12
  barfeed $'NEEDS|dotfiles|fix <b> & \xe2\x80\x94 line one\nline two|PR <#7>|12|hub/a:1'
  run "$MODULE"
  run tip
  assert_output --partial "fix &lt;b&gt; &amp; ? line one line two"
  assert_output --partial "PR &lt;#7&gt;"
}

@test "a long task or reason ends in ... so every line fits the bar channel's width" {
  feed hub/a:1=NEEDS:30:12
  barfeed "NEEDS|dotfiles|$(printf 't%.0s' $(seq 1 200))|$(printf 'r%.0s' $(seq 1 60))|12|hub/a:1"
  run "$MODULE"
  run plain
  assert_output --partial "ttt...  rrrrrrrrrrrrrrrrrrrrr...  12m"
  assert_equal "$(awk 'length > 120' <<< "$output")" ""
}

# comms-standard rule 12: the hover is checked against its channel. The negative control lints the same
# hover against a channel with fewer lines than it has, which must fail.
@test "the hover passes comms-lint --channel bar, and a channel with fewer lines fails it" {
  local args=() rows=() i
  for i in $(seq 1 60); do args+=("hub/w$i:1=WORKING:5"); rows+=("WORKING|dotfiles|task $i|busy|$i|hub/w$i:1"); done
  feed "${args[@]}"
  barfeed "${rows[@]}"
  run "$MODULE"
  plain > "$BATS_TEST_TMPDIR/hover.txt"
  run "$REPO_ROOT/.local/bin/comms-lint" --channel bar "$BATS_TEST_TMPDIR/hover.txt"
  assert_success
  { cat "$COMMS_CHANNELS"; printf '\n[channel.tight]\nmax_lines = 10\n'; } > "$BATS_TEST_TMPDIR/tight.toml"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/tight.toml" run "$REPO_ROOT/.local/bin/comms-lint" --channel tight "$BATS_TEST_TMPDIR/hover.txt"
  assert_failure
  assert_output --partial "too-many-lines"
}

@test "a stalled session turns the robot amber; the Stuck section, not a warning line, says which" {
  feed lab/uc-agent-1:1=WORKING:10 lab/uc-agent-9:1=STALLED:200:80
  barfeed 'STALLED|playground|chip art|PR #9 conflicts|80|lab/uc-agent-9:1'
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$Y" 2 1 0 0)"
  assert_equal "$(class)" warn
  run tip
  refute_output --partial "STALLED:"
  assert_line --index 1 "<b><span color='$Y'>Stuck</span></b>  1"
}

@test "no published bucket order reads amber and says so, never a built-in list" {
  feed lab/uc-agent-1:1=WORKING:10 novocab
  run "$MODULE"
  assert_equal "$(class)" warn
  run tip
  assert_output --partial "no agent_session_bucket on Prometheus"
}

@test "a CHAT session is counted and leaves the robot green: the human's conversation is not attention" {
  feed hub/dotfiles:1=CHAT:10
  barfeed 'CHAT|dotfiles|chat||10|hub/dotfiles:1'
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 1 0 0 0)"
  assert_equal "$(class)" inactive
  run tip
  assert_line "also 1 chat"
}

@test "the only sessions textfile older than five minutes is red: the tick stopped" {
  feed hub/dotfiles:1=WORKING:10 mtime=900
  run "$MODULE"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "fleet_sessions.prom on h1 is 15m old"
}

# With every file stale the join leaves no session series, only the bucket order and the file's age.
@test "every textfile stale is red with no sessions and no false bucket-order warning" {
  feed mtime=900
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$R" 0 0 0 0)"
  assert_equal "$(class)" critical
  run tip
  assert_output --partial "fleet_sessions.prom on h1 is 15m old"
  refute_output --partial "no agent_session_bucket"
}

# The leftover from a host that once held the lease: no host label, two days old, beside a fresh file.
@test "a stale textfile beside a fresh one is named once by its instance in amber, and the robot is not red" {
  feed hub/dotfiles:1=WORKING:10 stale=183000
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$Y" 1 1 0 0)"
  assert_equal "$(class)" warn
  run tip
  assert_equal "$(grep -c 'fleet_sessions.prom on' <<< "$output")" 1
  assert_line --index 1 --partial "<span color='$Y'>fleet_sessions.prom on 10.0.0.9:9100 is 2d2h old"
  refute_output --partial "color='$R'>fleet"
}

# Negative control: the same fleet with only fresh files has no such line and a green robot.
@test "a fresh textfile alone has no stale line and a green robot" {
  feed hub/dotfiles:1=WORKING:10
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$G" 1 1 0 0)"
  run tip
  refute_output --partial "fleet_sessions.prom on"
}

# Prometheus answers the stub's JSON whatever is asked, so the join and the selector are pinned on the query.
@test "the query reads age and idle with one selector and joins session series only to a fresh textfile" {
  feed hub/dotfiles:1=WORKING:10:3
  run "$MODULE"
  local q
  q="$(sed -n 's/.* --data-urlencode query=//p' "$FX/curl.args")"
  [[ "$q" == '{__name__=~"agent_session_(age|idle)_minutes"} and on (instance) (time() - node_textfile_mtime_seconds{file=~".*/fleet_sessions.prom"} < 300)'* ]]
  [[ "$q" != *"agent_session_age_minutes or "* ]]
  # the bucket order and the file itself are read unjoined: a stale file can be named, and a fleet
  # with every file stale still has its vocabulary
  [[ "$q" == *") or agent_session_bucket or node_textfile_mtime_seconds{file=~\".*/fleet_sessions.prom\"}" ]]
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
  barfeed -
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$Y" 7 1 1 1)"
  run tip
  assert_line --index 0 --partial "1 working. 7 sessions in all."
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
  assert_equal "$(text)" "$ICON <span color='$Y'>?</span>"
  assert_equal "$(class)" warn
}
