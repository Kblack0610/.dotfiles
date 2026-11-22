#!/usr/bin/env bats
# queue.sh: the waybar queue chip, the one chip for agent work flowing. The bar is two labelled totals,
# Q ready to start and D shipped today (merged a PR), with Q coloured by what is wrong. The hover opens
# with one sentence, "Queue: flowing." or the worst exception and its knob, then the urgent item a hold
# keeps waiting and each other exception, then Up next (the ready items by name from summary/bar, then
# the board rows after them), In flight, Today and Room.
# What these pin: a moving queue is green "flowing"; BLOCKED, a hold, flapping, a limit, an unhandled
# shepherd line are amber; queue-starved, a failed runner and a stopped pass are red; a hold that trips
# queue-starved is one red sentence; a gate is said once; the host whose pass ran last is the source and
# any other sender is ignored and named nowhere here (ar-4306; home-config's command-center rules
# raise it as the agents queue_senders row on the health chip); counts are Prometheus and names summary/bar,
# so a missing topic is one amber line with the counts kept; Prometheus down reads ?, and a number the
# feed lacks reads -, never 0; the hover fits the bar channel and comms-lint fails one that does not.
setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/queue.sh"
  # No palette unless a test writes one: a clone's own palette.css is per clone.
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  export CC_PROM_URL=http://prom.test FX="$BATS_TEST_TMPDIR" DISPATCH_NOW=100000 TZ=UTC
  export AGENT_MQTT_HOST=mqtt.test MQTT_SUB_FIXTURE="$BATS_TEST_TMPDIR/bar.json"
  export COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml"
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
[ -n "${CURL_FAIL:-}" ] && exit 7
cat "$FX/prom.json"
STUB
  chmod +x "$SANDBOX/bin/curl"
  feed
  barfeed
}

# feed [series=value ...] -> Prometheus's answer: a healthy queue on host h1 (39 ready, 32
# urgent, the oldest 12h59m, last pass 3m ago, last start 12m ago, 7 reaps; 60 queued, 14
# running, 6 on a PR, 10 waiting; 5 started and 4 done in 1h, 50 started and 40 done (2 failed) in 24h;
# 30 done and 18 added in 6h; 1522 agent board rows and 2200 on the backlog; 16 of 24 run units, 5 by hand), with the overrides applied. A
# series is topic.key (a feed number, summary_shepherd.* for the shepherd); <host>: (h2:, say) prefixes another
# host, dup: a second scrape of h1; a value of - drops the series. acct:<name>.<reason> is that
# account's claude_account_room_reason series (claude-acct textfile, no topic).
feed() {
  python3 - "$FX/prom.json" "$@" <<'PY'
import json, sys
s = {
    "summary_dispatch.runnable": 39, "summary_dispatch.runnable_urgent": 32, "summary_dispatch.runnable_high": 7,
    "summary_dispatch.oldest_runnable_s": 46758, "summary_dispatch.oldest_urgent_s": 46758,
    "summary_dispatch.last_pass_epoch": 100000 - 180, "summary_dispatch.last_run_start_epoch": 100000 - 720,
    "summary_dispatch.started_1h": 5, "summary_dispatch.failed_1h": 0,
    "summary_dispatch.started_24h": 50, "summary_dispatch.failed_24h": 2,
    "summary_dispatch.reaped_1h": 7, "summary_dispatch.flapping_items": 0,
    "summary_dispatch.queued": 60, "summary_dispatch.running": 14, "summary_dispatch.review": 6, "summary_dispatch.waiting": 10,
    "summary_dispatch.done_1h": 4, "summary_dispatch.done_6h": 30,
    "summary_dispatch.added_6h": 18, "summary_dispatch.done_24h": 40, "summary_dispatch.shipped_today": 12, "summary_dispatch.checks_today": 9,
    "summary_cards.figures_queue_on_deck": 39, "summary_cards.figures_projects_shipped_today": 12, "summary_cards.figures_projects_checks_closed": 9,
    "summary_dispatch.board_agent": 1522, "summary_dispatch.board_backlog": 2200,
    "summary_dispatch.room_live_runs": 16, "summary_dispatch.room_max_live": 24,
    "summary_dispatch.room_live_hand": 5, "summary_dispatch.room_total_live": 21, "summary_dispatch.room_load": 27.4,
    "summary_dispatch.room_load_cap": 36, "summary_dispatch.room_idle": 45.2,
    "summary_dispatch.room_min_idle": 30, "summary_dispatch.room_held_slots": 0,
    "summary_dispatch.room_held_account": 0,
    "runner_fleet_dispatch.failed": 0, "runner_fleet_dispatch.blocked": 0,
    "watch_queue_starved.tripped": 0,
}
for a in sys.argv[2:]:
    k, v = a.split("=")
    if v == "-": s.pop(k, None)
    else: s[k] = float(v)
res = []
for k, v in s.items():
    host, inst = "h1", "i1"
    pre = k.split(":")[0] if ":" in k else ""
    if pre not in ("", "dup", "acct"): host, inst, k = pre, "i-" + pre, k[len(pre) + 1:]
    if k.startswith("dup:"): inst, k = "i9", k[4:]
    if k.startswith("acct:"):
        name, reason = k[5:].split(".")
        res.append({"metric": {"__name__": "claude_account_room_reason", "account": name, "reason": reason,
                               "instance": inst}, "value": [0, str(v)]})
        continue
    topic, name = k.split(".")
    m = {"__name__": "mqtt_" + name, "topic": f"agents_{host}_main_{topic}"}
    m.update(host=host, instance=inst)
    res.append({"metric": m, "value": [0, str(v)]})
json.dump({"status": "success", "data": {"result": res}}, open(sys.argv[1], "w"))
PY
}

# barfeed [age=<s>] [err=<text>] [drain=<text>] [total=<n>] ['prio|project|kind|area|title|ready_min' ...]
# ['cand:key|title' ...] -> the retained summary/bar message, `hub bar --json` built <age> seconds ago
# (60 by default): ready items in the order given (hub-core's start order), total their count unless
# total= says more, and the board candidates. With no arguments: two items, one candidate, "6h +18/-30
# shrinking". `barfeed -` leaves no message on the broker.
barfeed() {
  python3 - "$MQTT_SUB_FIXTURE" "$@" <<'PY'
import json, os, sys
path, args = sys.argv[1], sys.argv[2:]
if args == ["-"]:
    os.path.exists(path) and os.remove(path)
    sys.exit()
if not args:
    args = ["urgent|dotfiles|fix|waybar|both hovers rewritten|20", "high|playground|feat|ui|chip art pass|135",
            "cand:ar-4400|retire the CI governor", "drain=6h +18/-30 shrinking"]
doc = {"as_of": 100000 - 60, "sessions": [], "ready": {"total": 0, "urgent": 0, "high": 0, "items": []},
       "candidates": [], "drain": None, "errors": []}
total = None
for a in args:
    if a.startswith("age="): doc["as_of"] = 100000 - int(a[4:]); continue
    if a.startswith("err="): doc["errors"].append(a[4:]); continue
    if a.startswith("drain="): doc["drain"] = a[6:]; continue
    if a.startswith("total="): total = int(a[6:]); continue
    if a.startswith("cand:"):
        key, title = a[5:].split("|")
        doc["candidates"].append({"project": "dotfiles", "key": key, "priority": "high", "title": title})
        continue
    prio, proj, kind, area, title, mins = a.split("|")
    doc["ready"]["items"].append({"slug": "s", "project": proj, "priority": prio, "kind": kind, "area": area,
                                  "title": title, "ready_min": int(mins)})
r = doc["ready"]
r["total"] = total if total is not None else len(r["items"])
r["urgent"] = sum(i["priority"] == "urgent" for i in r["items"])
r["high"] = sum(i["priority"] == "high" for i in r["items"])
json.dump(doc, open(path, "w"))
PY
}

text() { jq -r .text <<< "$output"; }
class() { jq -r .class <<< "$output"; }
tip() { jq -r .tooltip <<< "$output"; }
# plain: the hover as the human reads it, markup dropped and entities undone (pango_ansi, NO_COLOR).
plain() { jq -r .tooltip <<< "$output" | (. "$REPO_ROOT/.config/waybar/pango.sh"; NO_COLOR=1 pango_ansi); }
# bar <q> <d> -> the bar text: each label and colon in the label colour (no
# palette, so C_DIM; LABEL overrides), two spaces apart, the numbers as given.
bar() {
  local l=${LABEL:-#7f7f7f}
  printf "<span color='$l'>Q:</span>%s  <span color='$l'>D:</span>%s" "$1" "$2"
}
# g|y|r <text> -> the text in that level colour, as pango.sh paints it.
g() { printf "<span color='%s'>%s</span>" "$G" "$1"; }
y() { printf "<span color='%s'>%s</span>" "$Y" "$1"; }
r() { printf "<span color='%s'>%s</span>" "$R" "$1"; }
# head_is <painted what> <knob>: the hover's first line, the worst exception and what to do.
head_is() {
  run tip
  assert_line --index 0 "<b>Queue:</b> $1 $2."
}

@test "a deep queue that is moving is neutral: the two totals, nothing else" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
}

@test "a queue that flows says so, then Up next by name, In flight, Today and Room" {
  run "$MODULE"
  run tip
  assert_output "<b>Queue:</b> $(g flowing).

<b>Up next</b>  39 ready (32 urgent, 7 high)
<tt>  urgent  dotfiles    $(printf '%-90s' 'fix(waybar): both hovers rewritten')  20m
  high    playground  $(printf '%-90s' 'feat(ui): chip art pass')  2h15m</tt>
Then from the board: ar-4400 retire the CI governor
<b>In flight</b>  14 running, 6 on a PR, 10 waiting on you (sessions chip)

<b>Today</b>  12 shipped (merged a PR), 9 checks closed with no merge, $(y 2) failed in 24h; queue $(g '6h +18/-30 shrinking')
<b>Room</b>  $(g 21) of 24 sessions, load $(g 27) of 36, idle $(g 45%) (floor 30%)"
}

# Moved to their homes (dashboards.md, What moves): the legend, low water, self-heal, the Shepherd
# section, pass ages, the source host, the board and backlog counts, the 1h and 24h flow rows, run
# units and by hand, the as-of stamp.
@test "the hover has no gate internals: legend, self-heal, shepherd, pass ages, source host, board counts, as-of" {
  feed summary_shepherd.unhandled=0 summary_shepherd.passes_24h=40
  run "$MODULE"
  run tip
  refute_output --partial "ready to start next"
  refute_output --partial "self-heal"
  refute_output --partial "Shepherd"
  refute_output --partial "last pass"
  refute_output --partial "h1-main"
  refute_output --partial "1522"
  refute_output --partial "backlog"
  refute_output --partial "by hand"
  refute_output --partial "as of"
  refute_output --partial "<tt>Q ready"
}

@test "more ready than the rows shown is a +N line pointing at the Queue tab" {
  local rows=() i
  for i in $(seq 1 8); do rows+=("low|dotfiles|chore||item $i|$i"); done
  barfeed total=39 "${rows[@]}"
  run "$MODULE"
  run tip
  assert_output --partial "chore: item 5"
  refute_output --partial "item 6"
  assert_line "+34 more ready: click for the Queue tab"
  refute_output --partial "Then from the board"
}

@test "Up next rows shrink to the bar channel's line cap, never past it" {
  printf '[channel.bar]\nmax_lines = 14\nmax_line = 120\n' > "$BATS_TEST_TMPDIR/channels.toml"
  local rows=() i
  for i in $(seq 1 8); do rows+=("low|dotfiles|chore||item $i|$i"); done
  barfeed total=8 "${rows[@]}"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/channels.toml" run "$MODULE"
  run tip
  assert_output --partial "item 1"
  refute_output --partial "item 5"
  assert_line "+5 more ready: click for the Queue tab"
  assert [ "$(printf '%s\n' "$output" | wc -l)" -le 14 ]
}

@test "a line per account with no room comes out of the Up next rows, so the cap still holds" {
  printf '[channel.bar]\nmax_lines = 14\nmax_line = 120\n' > "$BATS_TEST_TMPDIR/channels.toml"
  local rows=() i
  for i in $(seq 1 8); do rows+=("low|dotfiles|chore||item $i|$i"); done
  barfeed total=8 "${rows[@]}"
  feed summary_dispatch.room_held_account=1 acct:a1.pace=1 acct:a2.pace=1 acct:a3.pace=1 acct:a4.pace=1
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/channels.toml" run "$MODULE"
  run tip
  assert_line "  a4: no room, pace"
  assert [ "$(printf '%s\n' "$output" | wc -l)" -le 14 ]
}

@test "no summary/bar is one amber line, and every count still shows" {
  barfeed -
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_output "<b>Queue:</b> $(g flowing).
$(y 'No item detail: no summary/bar on mqtt.test')

<b>Up next</b>  39 ready (32 urgent, 7 high)
<b>In flight</b>  14 running, 6 on a PR, 10 waiting on you (sessions chip)

<b>Today</b>  12 shipped (merged a PR), 9 checks closed with no merge, $(y 2) failed in 24h
<b>Room</b>  $(g 21) of 24 sessions, load $(g 27) of 36, idle $(g 45%) (floor 30%)"
}

@test "an old summary/bar says how old in amber and names no item from it" {
  barfeed age=900 'urgent|dotfiles|fix||old item|20'
  run "$MODULE"
  run tip
  assert_line --index 1 --partial "<span color='$Y'>No item detail: summary/bar is 15m old: is agent-mqtt-publish running"
  refute_output --partial "old item"
}

@test "a source summary/bar could not read is an amber line beside the items it has" {
  barfeed 'err=notes ptask: exit 2' 'urgent|dotfiles|fix||an item|20'
  run "$MODULE"
  run tip
  assert_line --index 1 "$(y 'Item detail incomplete: notes ptask: exit 2')"
  assert_output --partial "fix: an item"
}

@test "a title with markup, a newline or a non-ASCII character stays one escaped ASCII row" {
  barfeed $'urgent|dotfiles|fix||a <b> & \xe2\x80\x94 one\ntwo|20' 'cand:ar-1|<i>board</i>'
  run "$MODULE"
  run tip
  assert_output --partial "fix: a &lt;b&gt; &amp; ? one two"
  assert_output --partial "ar-1 &lt;i&gt;board&lt;/i&gt;"
}

@test "drain: shrinking is green, growing is amber, anything else plain, none left out" {
  barfeed 'drain=6h +122/-97 growing'
  run "$MODULE"
  run tip
  assert_output --partial "; queue $(y '6h +122/-97 growing')"
  barfeed 'drain=6h +5/-5 even'
  run "$MODULE"
  run tip
  assert_output --partial "; queue 6h +5/-5 even"
  barfeed 'urgent|dotfiles|fix||x|1'
  run "$MODULE"
  run tip
  assert_line "<b>Today</b>  12 shipped (merged a PR), 9 checks closed with no merge, $(y 2) failed in 24h"
}

@test "each Room number takes its own colour: green with room, amber near its limit, red past it" {
  feed summary_dispatch.room_live_runs=24 summary_dispatch.room_load=30 summary_dispatch.room_idle=35
  run "$MODULE"
  run tip
  assert_line "<b>Room</b>  $(y 21) of 24 sessions, load $(y 30) of 36, idle $(y 35%) (floor 30%)"
  feed summary_dispatch.room_load=40 summary_dispatch.room_idle=20
  run "$MODULE"
  run tip
  assert_line "<b>Room</b>  $(g 21) of 24 sessions, load $(r 40) of 36, idle $(r 20%) (floor 30%)"
}

@test "a gate that paused a pass with work still flowing is an amber Paused row; each account names its reasons" {
  feed summary_dispatch.room_held_slots=1
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue:</b> $(g flowing)."
  assert_line "<b>Paused</b>  $(y 'the fleet is at its session target of 24')"
  feed summary_dispatch.room_held_account=1 acct:main.pace=1 acct:main.five_hour=1 acct:alt.reserve=1
  run "$MODULE"
  run tip
  assert_output --partial "<b>Paused</b>  $(y 'no account has room')
  alt: no room, reserve
  main: no room, five_hour+pace"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "Paused"
}

# Account names and reasons come from a textfile: escaped, so one odd name cannot void the markup.
@test "an account name with markup characters is escaped in its row" {
  feed summary_dispatch.room_held_account=1 'acct:r&d.pace=1'
  run "$MODULE"
  run tip
  assert_line "  r&amp;d: no room, pace"
}

@test "BLOCKED heads the hover in amber with the gate that held it and its knob, said once" {
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.room_held_load=1
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(y 39)" 12)"
  assert_equal "$(class)" warn
  head_is "$(y 'the last pass started nothing: load 27 is over its cap of 36.')" "See the fleet-pace skill"
  refute_output --partial "Paused"
  assert_line --index 1 "$(y 'Urgent item waiting 20m: fix(waybar): both hovers rewritten')"
}

@test "a standing hold heads the hover with how long and what it blocks, never BLOCKED too" {
  feed runner_fleet_dispatch.blocked=1 summary_dispatch.held_s=7380 summary_dispatch.room_held_account=1
  run "$MODULE"
  assert_equal "$(class)" warn
  head_is "$(y 'dispatch paused 2h03m: no account has room.')" "Run claude-acct status"
  refute_output --partial "started nothing"
  refute_output --partial "Paused"
  feed summary_dispatch.held_s=600
  run "$MODULE"
  head_is "$(y 'dispatch paused 10m: the last pass left ready work waiting.')" "Run fleet-dispatch run --dry-run"
}

@test "a BLOCKED pass with no gate on record says so in one clean sentence" {
  feed runner_fleet_dispatch.blocked=1
  run "$MODULE"
  head_is "$(y 'the last pass started nothing.')" "Run fleet-dispatch run --dry-run"
  refute_output --partial ". ."
}

@test "every head sentence fits the bar channel's width, whichever gate holds the longest pause" {
  local k
  for k in slots load idle account assess other; do
    feed summary_dispatch.held_s=8639999 "summary_dispatch.room_held_$k=1" summary_dispatch.room_max_live=1000 \
      summary_dispatch.room_load=1000 summary_dispatch.room_load_cap=1000 summary_dispatch.room_idle=100 summary_dispatch.room_min_idle=100
    run "$MODULE"
    run plain
    assert_equal "$k: $(head -n 1 <<< "$output" | awk 'length > 120')" "$k: "
    feed runner_fleet_dispatch.blocked=1 "summary_dispatch.room_held_$k=1" summary_dispatch.room_max_live=1000 \
      summary_dispatch.room_load=1000 summary_dispatch.room_load_cap=1000 summary_dispatch.room_idle=100 summary_dispatch.room_min_idle=100
    run "$MODULE"
    run plain
    assert_equal "$k: $(head -n 1 <<< "$output" | awk 'length > 120')" "$k: "
  done
}

# queue-starved trips on a hold (its watch reads the runner's held_since): one cause, one red sentence.
@test "a hold that trips queue-starved is one red sentence, then the urgent item it keeps waiting in red" {
  feed summary_dispatch.held_s=7380 summary_dispatch.room_held_load=1 summary_dispatch.room_load=40 watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(class)" critical
  head_is "$(r 'dispatch paused 2h03m: load 40 is over its cap of 36.')" "See the fleet-pace skill"
  assert_line --index 1 "$(r 'Urgent item waiting 20m: fix(waybar): both hovers rewritten')"
  refute_output --partial "sat ready too long"
}

@test "a starve with no urgent item names the oldest high one; without summary/bar the wait is from Prometheus" {
  feed watch_queue_starved.tripped=1
  barfeed 'high|playground|feat|ui|chip art pass|135'
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(r 39)" 12)"
  head_is "$(r 'an urgent or high item sat ready too long, and nothing started it.')" "Run fleet-dispatch run --dry-run"
  assert_line --index 1 "$(r 'High item waiting 2h15m: feat(ui): chip art pass')"
  barfeed -
  run "$MODULE"
  run tip
  assert_line --index 1 "$(r 'Urgent item waiting 12h59m')"
}

# Negative control: a queue that flows names no waiting item, however old the urgent one.
@test "no hold, starve or BLOCKED pass, no urgent-item line" {
  run "$MODULE"
  run tip
  refute_output --partial "item waiting"
}

@test "each exception heads the hover in its level colour with its knob" {
  feed runner_fleet_dispatch.failed=1
  run "$MODULE"
  assert_equal "$(class)" critical
  head_is "$(r 'the fleet-dispatch runner failed.')" "Run agentctl logs fleet-dispatch"
  feed summary_dispatch.last_pass_epoch=$((100000 - 3600))
  run "$MODULE"
  head_is "$(r 'no dispatch pass in 1h00m.')" "Run systemctl --user status agentctl-fleet-dispatch.timer"
  feed summary_dispatch.flapping_items=2
  run "$MODULE"
  assert_equal "$(class)" warn
  head_is "$(y "2 item(s) flapping: a writer undoes reap's moves.")" "Run agentctl logs fleet-dispatch"
  feed summary_dispatch.could_start=3
  run "$MODULE"
  head_is "$(y '3 more could start: a limit holds them, not the machine.')" "Run fleet-dispatch headroom"
  feed summary_shepherd.unhandled=4
  run "$MODULE"
  head_is "$(y '4 shepherd due line(s) unhandled.')" "Use the shepherd skill, triage"
}

@test "the worst exception leads and the rest follow, each capitalised with its knob" {
  feed runner_fleet_dispatch.failed=1 summary_dispatch.flapping_items=2
  run "$MODULE"
  head_is "$(r 'the fleet-dispatch runner failed.')" "Run agentctl logs fleet-dispatch"
  assert_line --index 1 "$(y "2 item(s) flapping: a writer undoes reap's moves.") Run agentctl logs fleet-dispatch."
}

@test "a focus project reads in amber on the Up next line; no focus, no words" {
  feed summary_dispatch.focus_projects=2
  run "$MODULE"
  run tip
  assert_line "<b>Up next</b>  39 ready (32 urgent, 7 high; $(y '2 focus project(s) first'))"
  feed
  run "$MODULE"
  run tip
  refute_output --partial "focus"
}

@test "a feed without the room numbers reads - and says no headroom, never 0" {
  feed summary_dispatch.room_max_live=- summary_dispatch.running=- summary_cards.figures_projects_shipped_today=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 -)"
  run tip
  assert_line "<b>Room</b>  - (no headroom from a pass in the last 45m)"
  assert_line "<b>In flight</b>  - running, 6 on a PR, 10 waiting on you (sessions chip)"
  assert_output --partial "<b>Today</b>  - shipped (merged a PR)"
}

@test "a second scrape of the source host counts once" {
  feed dup:summary_dispatch.runnable=39
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
}

# ar-4306: cachyos-rog woke with a store frozen since 2026-11-15 and sent 328 ready; the max over
# hosts showed it. The host whose pass ran last is the source; the other is the health chip's to name.
@test "a stale host's bigger queue is ignored and named nowhere; its failed runner is not ours" {
  feed h2:summary_dispatch.runnable=328 h2:summary_dispatch.last_pass_epoch=$((100000 - 600000)) h2:summary_cards.figures_queue_on_deck=328 \
    h2:runner_fleet_dispatch.failed=1 h2:watch_queue_starved.tripped=1 \
    h3:summary_dispatch.runnable=5 h3:summary_dispatch.last_pass_epoch=2000
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
  run tip
  assert_line --index 0 "<b>Queue:</b> $(g flowing)."
  refute_output --partial "h2-main"
  refute_output --partial "h3-main"
  refute_output --partial "stale"
  refute_output --partial "sat ready too long"
  refute_output --partial "runner failed"
}

@test "a key the source lacks is never filled from a stale host" {
  feed runner_fleet_dispatch.failed=- watch_queue_starved.tripped=- \
    h2:summary_dispatch.runnable=328 h2:summary_dispatch.last_pass_epoch=$((100000 - 600000)) \
    h2:runner_fleet_dispatch.failed=1 h2:watch_queue_starved.tripped=1
  run "$MODULE"
  assert_equal "$(class)" ok
  run tip
  refute_output --partial "runner failed"
  refute_output --partial "sat ready too long"
}

@test "negative control: the host whose pass ran last is the source, even with the smaller queue" {
  feed h2:summary_dispatch.runnable=3 h2:summary_dispatch.last_pass_epoch=$((100000 - 60)) h2:summary_cards.figures_queue_on_deck=3
  run "$MODULE"
  assert_equal "$(text)" "$(bar 3 -)"
  run tip
  assert_output --partial "3 ready"
  refute_output --partial "39 ready"
  refute_output --partial "h1-main"
}

@test "with no pass on record anywhere every host counts by the max, and the head says no pass is on record" {
  feed summary_dispatch.last_pass_epoch=- h2:summary_dispatch.runnable=5
  run "$MODULE"
  assert_equal "$(jq -r .text <<< "$output" | grep -c 39)" 1
  assert_equal "$(class)" critical
  head_is "$(r 'no dispatch pass on record.')" "Run systemctl --user status agentctl-fleet-dispatch.timer"
  refute_output --partial "stale queue"
}

@test "Q, D, Up next and Today are hub cards figures; a feed without them reads -, never 0" {
  feed summary_cards.figures_queue_on_deck=- summary_cards.figures_projects_shipped_today=- summary_cards.figures_projects_checks_closed=-
  run "$MODULE"
  assert_equal "$(text)" "$(bar - -)"
  run tip
  assert_line --partial "<b>Up next</b>  - ready ("
  assert_line --partial "<b>Today</b>  - shipped (merged a PR), - checks closed with no merge,"
  # Negative control: the dispatch figures beside them are not what the chip reads.
  refute_output --partial "<b>Today</b>  12 shipped"
}

# The labels are the theme accent, palette.css's palette_accent. Negative controls: no palette,
# and an accent that is a level colour (Jackie Brown's warn amber), keep C_DIM.
@test "the labels take the palette accent; no palette or a level-colour accent keeps the dim grey" {
  echo '@define-color palette_accent #123456;' > "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(text)" "$(LABEL='#123456' bar 39 12)"
  echo '@define-color palette_accent #FFCC2F;' > "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  rm "$PANGO_PALETTE"
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
}

@test "no summary/dispatch on the feed reads - in amber with the publisher to check, never 0" {
  feed summary_dispatch.runnable=-
  run "$MODULE"
  # The bar reads the cards figures, so the amber and the head line say dispatch is missing.
  assert_equal "$(text)" "$(bar "$(y 39)" 12)"
  assert_equal "$(class)" warn
  head_is "$(y 'no dispatch numbers on the feed.')" "Run systemctl --user status agent-mqtt-publish.timer"
}

@test "Prometheus unreadable reads ? in amber, never blank" {
  CURL_FAIL=1 run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(y 'Q?')"
  assert_equal "$(class)" warn
  run tip
  assert_output "<b>Queue:</b> $(y 'cannot read http://prom.test')"
}

@test "every line fits the bar channel's width, even with every exception and long titles at once" {
  feed summary_dispatch.held_s=7380 summary_dispatch.room_held_account=1 watch_queue_starved.tripped=1 \
    runner_fleet_dispatch.failed=1 summary_dispatch.flapping_items=2 summary_dispatch.could_start=3 \
    summary_shepherd.unhandled=4 h2:summary_dispatch.runnable=328 h2:summary_dispatch.last_pass_epoch=1000 \
    acct:main.pace=1 summary_dispatch.focus_projects=2
  local long; long="$(printf 'word %.0s' $(seq 1 60))"
  barfeed "urgent|unity-core-playground-long|feat|area|$long|20" "cand:ar-1|$long" "cand:ar-2|$long" "err=$long"
  run "$MODULE"
  run plain
  assert_equal "$(awk 'length > 120' <<< "$output")" ""
}

# comms-standard rule 12: the hover is checked against its channel. The negative control lints the same
# hover against a channel with fewer lines than it has, which must fail.
@test "the hover passes comms-lint --channel bar, and a channel with fewer lines fails it" {
  local rows=() i
  for i in $(seq 1 9); do rows+=("high|dotfiles|feat|area|item $i|$i"); done
  feed summary_dispatch.held_s=7380 summary_dispatch.room_held_account=1 acct:main.pace=1 summary_dispatch.flapping_items=2
  barfeed total=39 "${rows[@]}" 'cand:ar-1|one' 'cand:ar-2|two' 'drain=6h +122/-97 growing'
  run "$MODULE"
  plain > "$BATS_TEST_TMPDIR/hover.txt"
  run "$REPO_ROOT/.local/bin/comms-lint" --channel bar "$BATS_TEST_TMPDIR/hover.txt"
  assert_success
  { cat "$COMMS_CHANNELS"; printf '\n[channel.tight]\nmax_lines = 6\n'; } > "$BATS_TEST_TMPDIR/tight.toml"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/tight.toml" run "$REPO_ROOT/.local/bin/comms-lint" --channel tight "$BATS_TEST_TMPDIR/hover.txt"
  assert_failure
  assert_output --partial "too-many-lines"
}
