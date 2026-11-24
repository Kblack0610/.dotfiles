#!/usr/bin/env bats
# queue.sh: the waybar queue chip, the one chip for agent work flowing. The bar is two labelled totals,
# Q ready to start and D shipped today (merged a PR), with Q in the Queue card's level colour. The hover
# lays out hub-core's Queue and Done cards from summary/cards: the Flow rows first ("Queue: Flowing." or
# the worst exception and its Do, then the rest), then Up next (the rows of the card's own Up next list,
# then the board rows after them from summary/bar), In flight, Today, Room and the card's as-of time.
# What these pin: every figure and sentence is the card's, coloured by the card's own levels, and the
# chip reads no Prometheus; the newest retained card wins; no card, an old card or a card with no Queue
# reads Q? in amber with why; a part the card lacks reads -, never 0; a missing summary/bar is one amber
# line with the counts kept; the hover fits the bar channel and comms-lint fails one that does not.
# The verdict itself (which exception, its level and Do) is hub-core's, tested in queue_verdict.rs.
setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  MODULE="$REPO_ROOT/.config/waybar/queue.sh"
  # No palette unless a test writes one: a clone's own palette.css is per clone.
  export PANGO_PALETTE="$BATS_TEST_TMPDIR/palette.css"
  G="#a6e34a" Y="#ffcc2f" R="#ef5734"
  export FX="$BATS_TEST_TMPDIR" DISPATCH_NOW=100000 TZ=UTC
  export AGENT_MQTT_HOST=mqtt.test MQTT_SUB_FIXTURE="$BATS_TEST_TMPDIR/broker.txt"
  export COMMS_CHANNELS="$REPO_ROOT/.config/comms-lint/channels.toml"
  # The chip reads no Prometheus: a curl call is logged, and a test that wants none asserts it.
  cat > "$SANDBOX/bin/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FX/curl.args"
exit 7
STUB
  chmod +x "$SANDBOX/bin/curl"
  cardfeed
  barfeed
}

# broker: the retained messages, the cards then the bar, one "<topic> <payload>" a line.
broker() { cat "$FX"/cards.msg "$FX"/bar.msg 2>/dev/null > "$MQTT_SUB_FIXTURE" || true; }

# cardfeed [age=<s>] [host=<h>] [level=<lvl>] [pill=<Card>.<Label>=<value>:<lvl>] [nopill=<Card>.<Label>]
# ['flow=<lvl>|<text>|<do>' ...] [noflow] ['up=<prio>|<project>|<text>|<age>' ...] [noup] [ready=<n>]
# [err=<text>] [noqueue] [nodone] [add] -> the retained
# summary/cards message, `hub cards --json --figures` built <age> seconds ago (60 by default) on h1, as
# widget_doc.rs lays it out. The default is a queue that flows: 39 on deck (32 urgent, 7 high), 14
# running, 6 on a PR, 2 failed in 24h, 21 of 24 sessions, load 27 of 36, and 12 shipped and 9 checks
# today. A flow= replaces the default "Flowing" row; up= replaces the default two Up next rows (ready=
# is the count in the list's head, 39 by default); add appends a second host's copy instead of
# replacing the message. `cardfeed -` leaves no card on the broker.
cardfeed() {
  python3 - "$FX/cards.msg" "$@" <<'PY'
import datetime, json, os, sys
path, args = sys.argv[1], sys.argv[2:]
if args == ["-"]:
    os.path.exists(path) and os.remove(path)
    sys.exit()
age, host, level, flows, errs, mode = 60, "h1", "ok", None, [], "w"
ups, ready = None, 39
pills = {
    "queue": [["Running", "14", "ok"], ["On a PR", "6", "ok"], ["On deck", "39", "ok"], ["Held", "3", "ok"],
              ["Urgent", "32", "ok"], ["High", "7", "ok"], ["Failed 24h", "2", "warn"],
              ["Sessions", "21 of 24", "ok"], ["Load", "27 of 36", "ok"]],
    "done": [["Shipped", "12", "ok"], ["Checks", "9", "ok"]],
}
cards = {"queue", "done"}
for a in args:
    k, _, v = a.partition("=")
    if k == "age": age = int(v)
    elif k == "host": host = v
    elif k == "level": level = v
    elif k == "flow": flows = (flows or []) + [v.split("|")]
    elif k == "noflow": flows = []
    elif k == "up": ups = (ups or []) + [v.split("|")]
    elif k == "noup": ups = []
    elif k == "ready": ready = int(v)
    elif k == "err": errs.append(v)
    elif k == "noqueue": cards.discard("queue")
    elif k == "nodone": cards.discard("done")
    elif k == "add": mode = "a"
    elif k in ("pill", "nopill"):
        card, _, rest = v.partition(".")
        label, _, val = rest.partition("=")
        pills[card] = [p for p in pills[card] if p[0] != label]
        if k == "pill":
            value, _, lvl = val.rpartition(":")
            pills[card].append([label, value, lvl])
if flows is None: flows = [["ok", "Flowing", ""]]
if ups is None: ups = [["urgent", "dotfiles", "fix(waybar): both hovers rewritten", "20m"],
                       ["high", "playground", "feat(ui): chip art pass", "2h15m"]]
def pill(p): return {"kind": "pill", "label": p[0], "value": p[1], "level": p[2]}
def row(text, sub, lvl):
    r = {"kind": "row", "text": text, "level": lvl}
    if sub: r["sub"] = sub
    return r
sections = []
if "queue" in cards:
    items = [{"kind": "metric", "value": "39", "unit": "on deck", "level": level},
             {"kind": "bar", "segments": [{"level": "ok", "n": 59}]}] + [pill(p) for p in pills["queue"]]
    items += [row(e, "", "warn") for e in errs]
    # Running and On a PR are lists of the card's own, which the chip counts as pills and never reads.
    items += [{"kind": "text", "text": "Running"}, row("run item", "dotfiles - 5m", "ok"),
              {"kind": "text", "text": "On a PR"}, row("parked item", "#7", "ok")]
    head = f"Up next: {ready} ready, {sum(u[0] == 'urgent' for u in ups)} urgent, {sum(u[0] == 'high' for u in ups)} high"
    items += [{"kind": "text", "text": head}]
    items += [row(t, f"{pr} - {proj} - {age}", "ok") for pr, proj, t, age in ups] or [row("Nothing ready", "", "ok")]
    if flows: items += [{"kind": "text", "text": "Flow"}] + [row(t, d, l) for l, t, d in flows]
    items.append({"kind": "text", "text": "agent-queue items by state (agent-queue list)"})
    sections.append({"id": "queue", "title": "Queue", "level": level, "actions": [], "items": items})
if "done" in cards:
    sections.append({"id": "done", "title": "Done", "level": "ok", "actions": [],
                     "items": [{"kind": "metric", "value": "12", "level": "ok"}] + [pill(p) for p in pills["done"]]})
at = datetime.datetime.fromtimestamp(100000 - age, datetime.timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
doc = {"version": 1, "title": "Fleet", "updated_at": at, "state": level, "ttl_s": 1800, "actions": [],
       "sections": sections, "figures": {"queue_on_deck": 39, "done_shipped": 12}}
with open(path, mode) as f:
    f.write(f"agents/{host}/summary/cards {json.dumps(doc)}\n")
PY
  broker
}

# barfeed [age=<s>] [err=<text>] [drain=<text>] ['cand:key|title' ...] -> the retained summary/bar message,
# `hub bar --json` built <age> seconds ago (60 by default): the board candidates and the drain, the two
# parts the chip reads from it. With no arguments: one candidate, "6h +18/-30 shrinking". `barfeed -`
# leaves no message on the broker.
barfeed() {
  python3 - "$FX/bar.msg" "$@" <<'PY'
import json, os, sys
path, args = sys.argv[1], sys.argv[2:]
if args == ["-"]:
    os.path.exists(path) and os.remove(path)
    sys.exit()
if not args:
    args = ["cand:ar-4400|retire the CI governor", "drain=6h +18/-30 shrinking"]
doc = {"as_of": 100000 - 60, "sessions": [], "ready": {"total": 0, "urgent": 0, "high": 0, "items": []},
       "candidates": [], "drain": None, "errors": []}
for a in args:
    if a.startswith("age="): doc["as_of"] = 100000 - int(a[4:]); continue
    if a.startswith("err="): doc["errors"].append(a[4:]); continue
    if a.startswith("drain="): doc["drain"] = a[6:]; continue
    if a.startswith("cand:"):
        key, title = a[5:].split("|")
        doc["candidates"].append({"project": "dotfiles", "key": key, "priority": "high", "title": title})
        continue
    sys.exit(f"barfeed: unknown argument {a}")
open(path, "w").write(f"agents/h1/summary/bar {json.dumps(doc)}\n")
PY
  broker
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
PAUSE_LINE='Dispatch paused 2h00m: load 31 is over its cap of 24'
PACE_DO='See the fleet-pace skill'

@test "a queue that flows is green Q's level: the two totals, the ok class" {
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
}

@test "a queue that flows says so, then Up next by name, In flight, Today, Room and the card's time" {
  run "$MODULE"
  run tip
  assert_output "<b>Queue:</b> $(g Flowing.)

<b>Up next</b>  39 ready (32 urgent, 7 high)
<tt>  fix(waybar): both hovers rewritten  urgent - dotfiles - 20m
  feat(ui): chip art pass  high - playground - 2h15m</tt>
+37 more ready: click for the Queue tab
Then from the board: ar-4400 retire the CI governor
<b>In flight</b>  14 running, 6 on a PR

<b>Today</b>  12 shipped (merged a PR), 9 checks closed with no merge, $(y 2) failed in 24h; queue $(g '6h +18/-30 shrinking')
<b>Room</b>  $(g 21) of 24 sessions, load $(g 27) of 36
As of 03:45, as the hub Queue tab read it then."
}

@test "each Flow row is a line in its level colour with its Do, in the card's order" {
  cardfeed level=bad "flow=bad|$PAUSE_LINE|$PACE_DO" 'flow=bad|Urgent item waiting 3h: fix(waybar): chip|' \
    'flow=warn|1 shepherd due line(s) unhandled|Use the shepherd skill, triage' 'flow=neutral|main: no room, pace|'
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue:</b> $(r "$PAUSE_LINE.") $PACE_DO."
  assert_line --index 1 "$(r 'Urgent item waiting 3h: fix(waybar): chip.')"
  assert_line --index 2 "$(y '1 shepherd due line(s) unhandled.') Use the shepherd skill, triage."
  assert_line --index 3 "main: no room, pace."
}

@test "Q and the class are the Queue card's level: amber warn, red critical" {
  cardfeed level=warn "flow=warn|$PAUSE_LINE|$PACE_DO"
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(y 39)" 12)"
  assert_equal "$(class)" warn
  cardfeed level=bad "flow=bad|$PAUSE_LINE|$PACE_DO"
  run "$MODULE"
  assert_equal "$(text)" "$(bar "$(r 39)" 12)"
  assert_equal "$(class)" critical
  # NEGATIVE CONTROL: a red Flow row on a card the publisher calls ok leaves Q plain; the card decides.
  cardfeed level=ok "flow=bad|$PAUSE_LINE|$PACE_DO"
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  assert_equal "$(class)" ok
}

@test "a card with no Flow rows says it has no verdict in amber" {
  cardfeed noflow
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue:</b> $(y 'No flow verdict on summary/cards.')"
}

@test "a source the card could not read is an amber line under the Flow rows" {
  cardfeed level=warn 'err=pipeline: state.json: bad json'
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue:</b> $(g Flowing.)"
  assert_line --index 1 "$(y 'Queue card incomplete: pipeline: state.json: bad json')"
}

@test "no summary/cards, an old one or one with no Queue card reads Q? in amber with why" {
  cardfeed -
  run "$MODULE"
  assert_success
  assert_equal "$(text)" "$(y 'Q?')"
  assert_equal "$(class)" warn
  run tip
  assert_output "<b>Queue:</b> $(y 'no summary/cards on mqtt.test')"
  cardfeed age=900
  run "$MODULE"
  run tip
  assert_output "<b>Queue:</b> $(y 'summary/cards is 15m old: is agent-mqtt-publish running on the lease holder?')"
  cardfeed noqueue
  run "$MODULE"
  run tip
  assert_output "<b>Queue:</b> $(y 'summary/cards has no Queue card')"
}

@test "the newest retained card wins: a former lease holder's old copy is ignored" {
  cardfeed age=200 host=old pill=queue.Running=99:ok "flow=bad|$PAUSE_LINE|$PACE_DO"
  cardfeed add age=30 host=new
  run "$MODULE"
  run tip
  assert_line --index 0 "<b>Queue:</b> $(g Flowing.)"
  assert_line --partial "<b>In flight</b>  14 running"
  # NEGATIVE CONTROL: the old copy made newest is the one read.
  cardfeed age=30 host=old pill=queue.Running=99:ok "flow=bad|$PAUSE_LINE|$PACE_DO"
  cardfeed add age=200 host=new
  run "$MODULE"
  run tip
  assert_line --partial "<b>In flight</b>  99 running"
}

@test "the chip reads no Prometheus, and both topics ride one subscribe" {
  run "$MODULE"
  assert_success
  assert [ ! -e "$FX/curl.args" ]
  assert_equal "$(cat "$MQTT_SUB_FIXTURE.args")" \
    "-h mqtt.test -p 1883 -v -t agents/+/summary/cards -t agents/+/summary/bar -W 1"
}

@test "a part the card lacks reads -, never 0; no Done card is D:-" {
  cardfeed nodone nopill=queue.Urgent 'nopill=queue.On deck' 'nopill=queue.Failed 24h'
  run "$MODULE"
  assert_equal "$(text)" "$(bar - -)"
  run tip
  assert_line "<b>Up next</b>  - ready (- urgent, 7 high)"
  assert_line --partial "<b>Today</b>  - shipped (merged a PR), - checks closed with no merge, - failed in 24h"
}

@test "Room numbers take their parts' colours; no Sessions part says no headroom, never 0" {
  cardfeed 'pill=queue.Sessions=24 of 24:warn' 'pill=queue.Load=40 of 36:bad'
  run "$MODULE"
  run tip
  assert_line "<b>Room</b>  $(y 24) of 24 sessions, load $(r 40) of 36"
  cardfeed nopill=queue.Load
  run "$MODULE"
  run tip
  assert_line "<b>Room</b>  $(g 21) of 24 sessions, load -"
  cardfeed nopill=queue.Sessions nopill=queue.Load
  run "$MODULE"
  run tip
  assert_line "<b>Room</b>  - (the Queue card has no room from a dispatch pass)"
}

@test "a focus project reads in amber on the Up next line; no part, no words" {
  cardfeed 'pill=queue.On focus=2:warn'
  run "$MODULE"
  run tip
  assert_line "<b>Up next</b>  39 ready (32 urgent, 7 high; $(y '2 project(s) on focus, running sprints'))"
  cardfeed
  run "$MODULE"
  run tip
  refute_output --partial "on focus"
}

@test "failed in 24h is in its part's level: amber above 0, plain at 0" {
  cardfeed 'pill=queue.Failed 24h=0:ok'
  run "$MODULE"
  run tip
  assert_line --partial ", $(g 0) failed in 24h"
}

@test "more ready than the rows shown is a +N line pointing at the Queue tab" {
  local rows=() i
  for i in $(seq 1 3); do rows+=("up=low|dotfiles|chore: item $i|${i}m"); done
  cardfeed ready=39 "${rows[@]}"
  run "$MODULE"
  run tip
  assert_output --partial "chore: item 3"
  assert_line "+36 more ready: click for the Queue tab"
}

@test "Up next rows shrink to the bar channel's line cap, never past it" {
  printf '[channel.bar]\nmax_lines = 14\nmax_line = 120\n' > "$BATS_TEST_TMPDIR/channels.toml"
  local rows=() i
  for i in $(seq 1 8); do rows+=("up=low|dotfiles|chore: item $i|${i}m"); done
  cardfeed ready=8 "${rows[@]}"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/channels.toml" run "$MODULE"
  run tip
  assert_output --partial "item 1"
  refute_output --partial "item 5"
  assert_line "+5 more ready: click for the Queue tab"
  assert [ "$(printf '%s\n' "$output" | wc -l)" -le 14 ]
}

@test "Flow rows come out of the Up next rows, so the cap still holds" {
  printf '[channel.bar]\nmax_lines = 14\nmax_line = 120\n' > "$BATS_TEST_TMPDIR/channels.toml"
  local rows=() i
  for i in $(seq 1 8); do rows+=("up=low|dotfiles|chore: item $i|${i}m"); done
  cardfeed level=warn ready=8 "${rows[@]}" 'flow=warn|Paused: no account has room|' 'flow=neutral|a1: no room, pace|' \
    'flow=neutral|a2: no room, pace|' 'flow=neutral|a3: no room, pace|'
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/channels.toml" run "$MODULE"
  run tip
  assert_line "a3: no room, pace."
  assert [ "$(printf '%s\n' "$output" | wc -l)" -le 14 ]
}

@test "no summary/bar is one amber line, and every card figure still shows" {
  barfeed -
  run "$MODULE"
  assert_equal "$(text)" "$(bar 39 12)"
  run tip
  assert_output "<b>Queue:</b> $(g Flowing.)
$(y 'No item detail: no summary/bar on mqtt.test')

<b>Up next</b>  39 ready (32 urgent, 7 high)
<tt>  fix(waybar): both hovers rewritten  urgent - dotfiles - 20m
  feat(ui): chip art pass  high - playground - 2h15m</tt>
+37 more ready: click for the Queue tab
<b>In flight</b>  14 running, 6 on a PR

<b>Today</b>  12 shipped (merged a PR), 9 checks closed with no merge, $(y 2) failed in 24h
<b>Room</b>  $(g 21) of 24 sessions, load $(g 27) of 36
As of 03:45, as the hub Queue tab read it then."
}

@test "an old summary/bar says how old in amber and names no item from it" {
  barfeed age=900 'cand:ar-9|old board row'
  run "$MODULE"
  run tip
  assert_line --index 1 --partial "<span color='$Y'>No item detail: summary/bar is 15m old: is agent-mqtt-publish running"
  refute_output --partial "old board row"
}

@test "a source summary/bar could not read is an amber line beside the items it has" {
  barfeed 'err=notes ptask: exit 2' 'cand:ar-8|a board row'
  run "$MODULE"
  run tip
  assert_line --index 1 "$(y 'Item detail incomplete: notes ptask: exit 2')"
  assert_output --partial "ar-8 a board row"
}

@test "a title or Flow row with markup, a newline or a non-ASCII character stays one escaped ASCII line" {
  barfeed 'cand:ar-1|<i>board</i>'
  cardfeed level=warn $'flow=warn|Urgent item waiting 3h: fix: a <b> &\ntwo|' $'up=urgent|dotfiles|fix: a <b> & \xe2\x80\x94 one\ntwo|20m'
  run "$MODULE"
  run tip
  assert_output --partial "fix: a &lt;b&gt; &amp; ? one two"
  assert_output --partial "ar-1 &lt;i&gt;board&lt;/i&gt;"
  assert_line --index 0 "<b>Queue:</b> $(y 'Urgent item waiting 3h: fix: a &lt;b&gt; &amp; two.')"
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
  barfeed 'cand:ar-1|x'
  run "$MODULE"
  run tip
  assert_line "<b>Today</b>  12 shipped (merged a PR), 9 checks closed with no merge, $(y 2) failed in 24h"
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

@test "every line fits the bar channel's width, even with long Flow rows, Dos and titles at once" {
  local long; long="$(printf 'word %.0s' $(seq 1 60))"
  cardfeed level=bad "flow=bad|$long|Run systemctl --user status agentctl-fleet-dispatch.timer" "flow=warn|$long|" \
    "err=$long" "up=urgent|unity-core-playground-long|feat(area): $long|20m"
  barfeed "cand:ar-1|$long" "cand:ar-2|$long" "err=$long"
  run "$MODULE"
  run plain
  assert_equal "$(awk 'length > 120' <<< "$output")" ""
  assert_line --index 0 --partial "... Run systemctl --user status agentctl-fleet-dispatch.timer."
}

# comms-standard rule 12: the hover is checked against its channel. The negative control lints the same
# hover against a channel with fewer lines than it has, which must fail.
@test "the hover passes comms-lint --channel bar, and a channel with fewer lines fails it" {
  local rows=() i
  for i in $(seq 1 9); do rows+=("up=high|dotfiles|feat(area): item $i|${i}m"); done
  cardfeed level=warn "${rows[@]}" "flow=warn|$PAUSE_LINE|$PACE_DO" 'flow=warn|2 item(s) flapping: a writer undoes reap'"'"'s moves|Run agentctl logs fleet-dispatch' \
    'flow=neutral|main: no room, pace|'
  barfeed 'cand:ar-1|one' 'cand:ar-2|two' 'drain=6h +122/-97 growing'
  run "$MODULE"
  plain > "$BATS_TEST_TMPDIR/hover.txt"
  run "$REPO_ROOT/.local/bin/comms-lint" --channel bar "$BATS_TEST_TMPDIR/hover.txt"
  assert_success
  { cat "$COMMS_CHANNELS"; printf '\n[channel.tight]\nmax_lines = 6\n'; } > "$BATS_TEST_TMPDIR/tight.toml"
  COMMS_CHANNELS="$BATS_TEST_TMPDIR/tight.toml" run "$REPO_ROOT/.local/bin/comms-lint" --channel tight "$BATS_TEST_TMPDIR/hover.txt"
  assert_failure
  assert_output --partial "too-many-lines"
}
