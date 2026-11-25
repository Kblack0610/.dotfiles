#!/usr/bin/env bats
# desk: the state file picks each slot's part, `use` refuses what it does not know and
# leaves the state alone, `signal` reads the chip's number from the real config.base, and
# nothing touches a real bar, notifier or systemd (stubs log every call).

setup() {
  load '../vendor/bats-support/load'
  load '../vendor/bats-assert/load'
  load '../helpers/sandbox'
  sandbox_init basic
  DESK="$REPO_ROOT/.local/bin/desk"
  STATE="$HOME/.local/state/desk/parts"
  export FX="$BATS_TEST_TMPDIR"
  for b in pkill dunstctl waybar dunst; do
    printf '#!/usr/bin/env bash\necho "%s $*" >> "$FX/calls.log"\n' "$b" > "$SANDBOX/bin/$b"
    chmod +x "$SANDBOX/bin/$b"
  done
}

# The default bar is noctalia (the first row of desk's parts), so a test of waybar's
# path records it first.
on_waybar() { mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-classic" > "$STATE"; }

@test "no state file: each slot runs its first part" {
  run "$DESK" current
  assert_success
  assert_output $'bar=noctalia\nnotify=dunst'
}

@test "use records the part and restarts its unit" {
  run "$DESK" use bar waybar-classic
  assert_success
  assert_equal "$(cat "$STATE")" "bar=waybar-classic"
  run grep -x 'systemctl --user restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_success
}

@test "use refuses an unknown part and leaves the state alone" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-classic" > "$STATE"
  run "$DESK" use bar bogus
  assert_failure 2
  assert_output --partial "'bogus' is not a bar part"
  assert_equal "$(cat "$STATE")" "bar=waybar-classic"
  run grep -c restart "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "use refuses a part whose binary is missing" {
  # A PATH with the tools desk needs and no dunst, real or stub.
  local only="$BATS_TEST_TMPDIR/only" t
  mkdir -p "$only"
  for t in bash env awk grep mkdir mv dirname readlink cat xargs sort head; do ln -s "$(command -v "$t")" "$only/$t"; done
  PATH="$only" run "$DESK" use notify dunst
  assert_failure 1
  assert_output --partial "needs dunst"
  [ ! -e "$STATE" ]
}

@test "a part this checkout no longer knows falls back to the default" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=retired-bar" > "$STATE"
  run "$DESK" get bar
  assert_output noctalia
}

@test "start starts every slot's unit" {
  run "$DESK" start
  assert_success
  run grep -c -x -e 'systemctl --user start noctalia.service' -e 'systemctl --user start dunst.service' "$NOTES_FIXTURE/calls.log"
  assert_output 2
}

@test "signal reads each chip's number from config.base and the pin config" {
  on_waybar
  run "$DESK" signal custom/gungan custom/passthrough custom/machines custom/ci
  assert_success
  run cat "$FX/calls.log"
  assert_output $'pkill -RTMIN+9 -x waybar\npkill -RTMIN+10 -x waybar\npkill -RTMIN+11 -x waybar'
}

@test "signal on a chip with no signal key exits 2 and signals nothing" {
  run "$DESK" signal custom/nonexistent
  assert_failure 2
  [ ! -e "$FX/calls.log" ]
}

@test "notify maps each verb to the running notifier" {
  for v in close close-all history dnd; do "$DESK" notify "$v"; done
  run cat "$FX/calls.log"
  assert_output $'dunstctl close\ndunstctl close-all\ndunstctl history-pop\ndunstctl set-paused toggle'
  run "$DESK" notify bogus
  assert_failure 2
}

@test "a restart that fails puts the old choice back and exits 1" {
  mkdir -p "$(dirname "$STATE")" && printf 'bar=waybar-classic\nnotify=dunst\n' > "$STATE"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/systemctl"
  run "$DESK" use bar waybar-classic
  assert_failure 1
  assert_output --partial "did not start"
  assert_equal "$(cat "$STATE")" $'bar=waybar-classic\nnotify=dunst'
}

@test "start exits non-zero when a unit fails, so desk.service shows failed" {
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/systemctl"
  run "$DESK" start
  assert_failure
  assert_output --partial "bar did not start"
}

@test "signal still signals the known chips when one id has no number" {
  on_waybar
  run "$DESK" signal custom/nonexistent custom/gungan
  assert_failure 2
  assert_output --partial "no signal for 'custom/nonexistent'"
  run cat "$FX/calls.log"
  assert_output 'pkill -RTMIN+9 -x waybar'
}

@test "notify under swaync maps each verb to swaync-client" {
  printf '#!/usr/bin/env bash\necho "swaync-client $*" >> "$FX/calls.log"\n' > "$SANDBOX/bin/swaync-client"
  chmod +x "$SANDBOX/bin/swaync-client"
  mkdir -p "$(dirname "$STATE")" && echo "notify=swaync" > "$STATE"
  for v in close close-all history dnd; do "$DESK" notify "$v"; done
  run cat "$FX/calls.log"
  assert_output $'swaync-client --hide-latest\nswaync-client --hide-all\nswaync-client -t -sw\nswaync-client -d -sw'
}

@test "switching the notifier restarts the bar, so its notify chip rebinds" {
  on_waybar
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/swaync" && chmod +x "$SANDBOX/bin/swaync"
  run "$DESK" use notify swaync
  assert_success
  run grep -x -e 'systemctl --user restart swaync.service' -e 'systemctl --user restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_output $'systemctl --user restart swaync.service\nsystemctl --user restart waybar.service'
  # Choosing the notifier already running leaves the bar alone.
  : > "$NOTES_FIXTURE/calls.log"
  run "$DESK" use notify swaync
  assert_success
  run grep -c 'restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_output 0
}

@test "waybar-modern signals waybar the same way as classic" {
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-modern" > "$STATE"
  run "$DESK" signal custom/gungan
  assert_success
  run cat "$FX/calls.log"
  assert_output 'pkill -RTMIN+9 -x waybar'
}

@test "launch.sh gives waybar the stylesheet of the bar part desk records" {
  mkdir -p "$HOME/.local/bin" && ln -s "$REPO_ROOT/.local/bin/desk" "$HOME/.local/bin/desk"
  export XDG_CONFIG_HOME="$BATS_TEST_TMPDIR" WAYBAR_BIN="$SANDBOX/bin/waybar"
  run "$REPO_ROOT/.config/waybar/launch.sh"
  assert_success
  mkdir -p "$(dirname "$STATE")" && echo "bar=waybar-modern" > "$STATE"
  run "$REPO_ROOT/.config/waybar/launch.sh"
  assert_success
  run grep -o -e '-s .*' "$FX/calls.log"
  assert_output $'-s '"$BATS_TEST_TMPDIR"$'/waybar/style.css\n-s '"$BATS_TEST_TMPDIR"$'/waybar/style-modern.css'
}

@test "style-modern.css layers palette and modern layout after the theme" {
  run grep '^@import' "$REPO_ROOT/.config/waybar/style-modern.css"
  assert_output $'@import url("style.css");\n@import url("palette.css");\n@import url("layout-modern.css");'
}

@test "noctalia is a bar part, run by its own unit" {
  run "$DESK" parts bar
  assert_output --partial 'bar noctalia noctalia.service'
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/noctalia" && chmod +x "$SANDBOX/bin/noctalia"
  run "$DESK" use bar noctalia
  assert_success
  run grep -x 'systemctl --user restart noctalia.service' "$NOTES_FIXTURE/calls.log"
  assert_success
  # A notifier switch under noctalia restarts noctalia, never waybar.
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/swaync" && chmod +x "$SANDBOX/bin/swaync"
  : > "$NOTES_FIXTURE/calls.log"
  run "$DESK" use notify swaync
  run grep -c -e 'restart noctalia.service' -e 'restart waybar.service' "$NOTES_FIXTURE/calls.log"
  assert_output 1
  run grep -c 'restart noctalia.service' "$NOTES_FIXTURE/calls.log"
  assert_output 1
}

@test "signal under noctalia sends each number once over the plugin IPC, no pkill" {
  printf '#!/usr/bin/env bash\necho "noctalia $*" >> "$FX/calls.log"\n' > "$SANDBOX/bin/noctalia" && chmod +x "$SANDBOX/bin/noctalia"
  mkdir -p "$(dirname "$STATE")" && echo "bar=noctalia" > "$STATE"
  run "$DESK" signal custom/gungan custom/ci custom/passthrough custom/gungan
  assert_success
  run cat "$FX/calls.log"
  assert_output $'noctalia msg plugin dotfiles/chips:chip all refresh 9\nnoctalia msg plugin dotfiles/chips:chip all refresh 10\nnoctalia msg plugin dotfiles/chips:chip all refresh 11'
}

# A config.base with a chip per way one runs (poll, once, stream, gated), plus format
# icons, an empty exec and a stream that ends, for `desk chip`.
chip_fixture() {
  export DESK_WAYBAR_DIR="$BATS_TEST_TMPDIR/waybar"
  mkdir -p "$DESK_WAYBAR_DIR"
  cat > "$DESK_WAYBAR_DIR/config.base" <<'JSON'
{
    // a comment line, as the real config.base has
    "custom/poll": { "exec": "printf '{\"text\":\"<b>ci</b> &amp; ok\",\"tooltip\":\"<span>2 down</span>\",\"class\":[\"warn\",\"x\"]}\\n'", "interval": 60, "signal": 10, "on-click": "hub --tab ci", "on-click-middle": "hub --tab runners" },
    "custom/once": { "exec": "echo plain text", "interval": "once", "signal": 9 },
    "custom/stream": { "exec": "printf 'a\\nb\\n'", "return-type": "json" },
    "custom/gated": { "exec": "echo shown", "exec-if": "false" },
    "custom/icon": { "exec": "printf '{\"text\":\"3\",\"alt\":\"dnd\"}\\n{\"text\":\"4\"}\\n'", "format": "{icon} {}", "format-icons": { "dnd": "D", "default": "N" } },
    "custom/blank": { "exec": "true" },
    "custom/rich": { "exec": "cat \"$DESK_WAYBAR_DIR/rich.json\"" },
    "custom/again": { "exec": "echo tick", "restart-interval": 0 },
    "bluetooth": { "format": "x" }
}
JSON
}

@test "chip prints how each module runs: poll, once or stream" {
  chip_fixture
  run "$DESK" chip custom/poll
  assert_output '{"mode":"poll","interval":60,"signal":10,"click":"hub --tab ci","right_click":"","middle_click":"hub --tab runners"}'
  run "$DESK" chip custom/once
  assert_output --partial '"mode":"once"'
  run "$DESK" chip custom/stream
  assert_output --partial '"mode":"stream"'
}

@test "chip run prints plain JSON: no pango, entities decoded, the first class" {
  chip_fixture
  run "$DESK" chip custom/poll run
  assert_success
  assert_output '{"text":"ci & ok","tooltip":"2 down","detail":[[{"t":"2 down"}]],"class":"warn"}'
  run "$DESK" chip custom/once run
  assert_output '{"text":"plain text","tooltip":"","detail":[],"class":""}'
  run "$DESK" chip custom/stream run
  assert_output $'{"text":"a","tooltip":"","detail":[],"class":""}\n{"text":"b","tooltip":"","detail":[],"class":""}'
}

@test "chip run parses the tooltip's pango into styled runs per line for the detail panel" {
  chip_fixture
  # A bold title, a coloured span with alpha, a <tt> table row with a nested colour, entities,
  # and a stray "<" that is text, not a tag (the negative control).
  jq -cn '{text: "ci", tooltip: "<b>CI runners</b> <span color='"'"'#ffcc2f'"'"' alpha='"'"'60%'"'"'>busy</span>\n<tt>pool  <span foreground=\"#ef5734\">2/2</span></tt>\na < b &amp; c"}' \
    > "$DESK_WAYBAR_DIR/rich.json"
  run "$DESK" chip custom/rich run
  assert_success
  local d
  d=$(jq -c '.detail' <<<"$output")
  run jq -c 'map(map(.t) | join(""))' <<<"$d"
  assert_output '["CI runners busy","pool  2/2","a < b & c"]'
  run jq -c '[.[0][0].b, .[0][2].c, .[0][2].a, .[1][0].m, .[1][1].m, .[1][1].c, ([.[2][] | keys[]] | unique)]' <<<"$d"
  assert_output '[true,"#ffcc2f",0.6,true,true,"#ef5734",["t"]]'
}

@test "chip run gives the text's colours as runs for the bar; text with no colour has none" {
  chip_fixture
  jq -cn '{text: "<span color='"'"'#6495ed'"'"'>Q:</span><span color='"'"'#ef5734'"'"'>4</span>  <b>S:</b>9"}' > "$DESK_WAYBAR_DIR/rich.json"
  run "$DESK" chip custom/rich run
  assert_success
  run jq -c '[.text, .runs]' <<<"$output"
  assert_output '["Q:4  S:9",[{"c":"#6495ed","t":"Q:"},{"c":"#ef5734","t":"4"},{"t":"  "},{"b":true,"t":"S:"},{"t":"9"}]]'
  # A dim run alone (the printer's off machine) is drawn run by run too.
  jq -cn '{text: "<span alpha='"'"'50%'"'"'>A1</span> on"}' > "$DESK_WAYBAR_DIR/rich.json"
  run "$DESK" chip custom/rich run
  run jq -c '.runs' <<<"$output"
  assert_output '[{"a":0.5,"t":"A1"},{"t":" on"}]'
  # Negative control: bold alone is no colour, so the chip stays one label in its class role.
  jq -cn '{text: "<b>ci</b> ok"}' > "$DESK_WAYBAR_DIR/rich.json"
  run "$DESK" chip custom/rich run
  run jq -c 'has("runs")' <<<"$output"
  assert_output false
}

@test "chip run detail keeps only a #rrggbb text colour and drops a tooltip with no text" {
  chip_fixture
  # bgcolor is not the text colour, and a named colour is not one the panel can draw.
  jq -cn '{text: "x", tooltip: "<span bgcolor=\"#000000\" foreground=\"#ff0000\">a</span><span color=\"red\">b</span>"}' \
    > "$DESK_WAYBAR_DIR/rich.json"
  run "$DESK" chip custom/rich run
  run jq -c '.detail' <<<"$output"
  assert_output '[[{"c":"#ff0000","t":"a"},{"t":"b"}]]'
  jq -cn '{text: "x", tooltip: "<b></b>\n<tt></tt>"}' > "$DESK_WAYBAR_DIR/rich.json"
  run "$DESK" chip custom/rich run
  run jq -c '.detail' <<<"$output"
  assert_output '[]'
}

@test "chip run on a failing exec-if prints an empty chip and never runs the exec" {
  chip_fixture
  run "$DESK" chip custom/gated run
  assert_success
  assert_output '{"text":"","tooltip":"","class":""}'
}

@test "chip run applies the module's format, {icon} by alt and else the default icon" {
  chip_fixture
  run "$DESK" chip custom/icon run
  assert_success
  assert_output $'{"text":"D 3","tooltip":"","detail":[],"class":""}\n{"text":"N 4","tooltip":"","detail":[],"class":""}'
}

@test "chip run on an exec that prints nothing prints nothing, which hides the chip" {
  chip_fixture
  run "$DESK" chip custom/blank run
  assert_success
  assert_output ''
}

@test "chip stream runs the exec again when it ends, and exits 0 once the reader closes" {
  chip_fixture
  # One line per run, so three lines are two restarts. timeout is the hang guard: a
  # stream that never noticed the closed pipe would end 124, not 0.
  run bash -c "set -o pipefail; timeout 10 '$DESK' chip custom/again stream | head -n 3"
  assert_success
  assert_output $'{"text":"tick","tooltip":"","detail":[],"class":""}\n{"text":"tick","tooltip":"","detail":[],"class":""}\n{"text":"tick","tooltip":"","detail":[],"class":""}'
}

@test "chip exits 2 on an unknown module and on one with no exec" {
  chip_fixture
  run "$DESK" chip custom/nope
  assert_failure 2
  assert_output --partial "no module 'custom/nope'"
  run "$DESK" chip bluetooth run
  assert_failure 2
  assert_output --partial "has no exec"
}

@test "every chip in noctalia's config.toml is a module desk can run" {
  local id
  for id in $(grep -o 'module = "[^"]*"' "$REPO_ROOT/.config/noctalia/config.toml" | cut -d'"' -f2); do
    run "$DESK" chip "$id"
    assert_success
  done
}

@test "the chips plugin manifest parses and every key it names is translated" {
  local dir="$REPO_ROOT/.local/share/noctalia/plugins/dotfiles-chips" key
  run python3 -c 'import sys,tomllib; tomllib.load(open(sys.argv[1],"rb"))' "$dir/plugin.toml"
  assert_success
  for key in $(grep -oE '(label|description)_key = "[^"]+"' "$dir/plugin.toml" | cut -d'"' -f2); do
    run jq -e --arg k "$key" 'getpath($k | split(".")) // .[$k] | strings' "$dir/translations/en.json"
    assert_success
  done
}

# The chips plugin under plain Lua with a stub Noctalia (helpers/noctalia-chips-sim.lua lists
# the commands), fed the lines given as arguments.
chips_sim() {
  local lua
  lua=$(command -v lua5.4 || command -v lua) || fail "no lua on PATH"
  printf '%s\n' "$@" | "$lua" "$REPO_ROOT/tests/helpers/noctalia-chips-sim.lua" \
    "$REPO_ROOT/.local/share/noctalia/plugins/dotfiles-chips"
}

@test "hovering a chip opens its dropdown, and leaving closes it after the grace" {
  run chips_sim 'chip custom/ci' 'hover custom/ci on' settle show 'hover custom/ci off' 'tick 200' show 'tick 250' show
  assert_success
  assert_output $'panel=custom/ci\ntooltip custom/ci=\npanel=custom/ci\ntooltip custom/ci=\npanel=closed\ntooltip custom/ci='
}

@test "the dropdown stays open while the pointer is in it, and closes when it leaves" {
  run chips_sim 'chip custom/ci' 'hover custom/ci on' settle 'hover custom/ci off' 'panelhover on' 'tick 1000' show 'panelhover off' 'tick 500' show
  assert_success
  assert_output $'panel=custom/ci\ntooltip custom/ci=\npanel=closed\ntooltip custom/ci='
}

@test "a click pins a hovered dropdown open, and a second click closes it" {
  run chips_sim 'chip custom/ci' 'hover custom/ci on' settle 'click custom/ci' 'hover custom/ci off' 'tick 1000' show 'click custom/ci' settle show
  assert_success
  assert_output $'panel=custom/ci\ntooltip custom/ci=\npanel=closed\ntooltip custom/ci='
}

@test "sweeping across chips opens the dropdown once, on the chip the pointer stopped on" {
  run chips_sim 'chip custom/ci' 'chip custom/fleet' 'hover custom/ci on' 'hover custom/ci off' 'hover custom/fleet on' settle show
  assert_success
  assert_line --index 0 'panel=custom/fleet'
}

@test "hovering another chip does not switch a pinned dropdown, nor one opened by a Super+A b letter" {
  run chips_sim 'chip custom/ci' 'chip custom/fleet' 'click custom/ci' settle 'hover custom/fleet on' 'hover custom/fleet off' 'tick 1000' show
  assert_success
  assert_line --index 0 'panel=custom/ci'
  run chips_sim 'chip custom/ci' 'letter custom/ci' settle 'tick 1000' show
  assert_success
  assert_line --index 0 'panel=custom/ci'
}

@test "the panel counts hover across its nodes, enter before leave, string or boolean" {
  # Line to line: the next node's enter arrives before the last one's leave.
  run chips_sim 'chip custom/ci' 'hover custom/ci on' settle 'hover custom/ci off' 'panelhover on' 'panelhover on bool' 'panelhover off' 'tick 1000' show 'panelhover off bool' 'tick 500' show
  assert_success
  assert_line --index 0 'panel=custom/ci'
  assert_line --index 2 'panel=closed'
}

@test "a click while a hover's open is on its way pins it, and an open the host never answers goes stale" {
  run chips_sim 'chip custom/ci' 'hover custom/ci on' 'click custom/ci' settle 'hover custom/ci off' 'tick 1000' show
  assert_success
  assert_line --index 0 'panel=custom/ci'
  run chips_sim 'chip custom/ci' 'hover custom/ci on' drop 'hover custom/ci off' 'tick 1200' 'hover custom/ci on' settle show
  assert_success
  assert_line --index 0 'panel=custom/ci'
}

@test "a chip with dropdown = false keeps its plain tooltip and opens nothing on hover" {
  run chips_sim 'chip custom/mic nodrop' 'hover custom/mic on' settle show
  assert_success
  assert_output $'panel=closed\ntooltip custom/mic=custom/mic first|custom/mic second'
}

@test "every Super+A d leaf runs desk use for the part it names, and every part has a leaf" {
  load '../helpers/hypr'
  local leaves parts
  # Each leaf as "<slot> <part>" from the command it runs, kept only when its label says the same.
  leaves="$(hypr_dump registry | jq -r '.[] | select(.submap == "pinbar-desk" and (.arg | test("desk use")))
    | (.arg | capture("desk use (?<s>[^ ]+) (?<p>[^ )]+)")) as $c
    | select(.description == "\($c.s): \($c.p)") | "\($c.s) \($c.p)"' | sort)"
  parts="$("$DESK" parts | awk '{ print $1, $2 }' | sort)"
  [ -n "$leaves" ]
  assert_equal "$leaves" "$parts"
}

@test "noctalia's bar places every widget once, every group token resolves, and every pod matches the bar's style" {
  # A widget left out of every lane and pod never draws, and a group does not inherit the
  # bar's capsule_* style, so a pod restyled alone stops matching. Nothing else says so.
  run python3 -c '
import sys, tomllib
c = tomllib.load(open(sys.argv[1], "rb"))
bar = c["bar"]["default"]
groups = {g["id"]: g for g in bar.get("capsule_group", [])}
lanes = [w for lane in ("start", "center", "end") for w in bar.get(lane, [])]
tokens = [w[6:] for w in lanes if w.startswith("group:")]
placed = [w for w in lanes if not w.startswith("group:")] + [m for g in groups.values() for m in g["members"]]
bad = ["no group " + t for t in tokens if t not in groups]
bad += ["group unused: " + g for g in groups if g not in tokens]
bad += ["not on the bar: " + w for w in sorted(set(c["widget"]) - set(placed))]
bad += ["placed twice: " + w for w in sorted({w for w in placed if placed.count(w) > 1})]
style = {"fill": bar["capsule_fill"], "border": bar["capsule_border"], "padding": bar["capsule_padding"]}
bad += ["pod " + i + " style differs" for i, g in groups.items() if {k: g.get(k) for k in style} != style]
bad += ["pods differ in widget_spacing"] if len({g.get("widget_spacing") for g in groups.values()}) > 1 else []
print(*bad, sep="\n")
sys.exit(1 if bad else 0)
' "$REPO_ROOT/.config/noctalia/config.toml"
  assert_success
}

@test "notify show sends the replace hint and keeps the server id; drop closes it once" {
  printf '#!/usr/bin/env bash\necho "notify-send $*" >> "$FX/calls.log"; echo 77\n' > "$SANDBOX/bin/notify-send"
  # GetNameOwner answers with $FX/owner (the notifier process); any other call is a close.
  printf '#!/usr/bin/env bash\n[[ "$*" == *GetNameOwner* ]] && { cat "$FX/owner"; exit; }\necho "gdbus ${*: -1}" >> "$FX/calls.log"\n' > "$SANDBOX/bin/gdbus"
  chmod +x "$SANDBOX/bin/notify-send" "$SANDBOX/bin/gdbus"
  export XDG_RUNTIME_DIR="$FX/run"
  echo "(':1.7',)" > "$FX/owner"
  # show and drop never look at the slot: the same under swaync.
  mkdir -p "$(dirname "$STATE")" && echo "notify=swaync" > "$STATE"
  run "$DESK" notify show hint -t 100 title body
  assert_success
  assert_equal "$(cat "$FX/run/desk/notify-hint.id")" "77 (':1.7',)"
  run "$DESK" notify drop hint
  assert_success
  run "$DESK" notify drop hint
  assert_success
  run cat "$FX/calls.log"
  assert_output $'notify-send -p -h string:x-canonical-private-synchronous:hint -t 100 title body\ngdbus 77'
  [ ! -e "$FX/run/desk/notify-hint.id" ]
}

@test "notify drop leaves alone an id a restarted notifier may have handed to another popup" {
  printf '#!/usr/bin/env bash\necho 77\n' > "$SANDBOX/bin/notify-send"
  printf '#!/usr/bin/env bash\n[[ "$*" == *GetNameOwner* ]] && { cat "$FX/owner"; exit; }\necho "gdbus ${*: -1}" >> "$FX/calls.log"\n' > "$SANDBOX/bin/gdbus"
  chmod +x "$SANDBOX/bin/notify-send" "$SANDBOX/bin/gdbus"
  export XDG_RUNTIME_DIR="$FX/run"
  echo "(':1.7',)" > "$FX/owner"
  run "$DESK" notify show hint title
  assert_success
  echo "(':1.9',)" > "$FX/owner"
  run "$DESK" notify drop hint
  assert_success
  [ ! -e "$FX/calls.log" ]
  [ ! -e "$FX/run/desk/notify-hint.id" ]
  run "$DESK" notify show
  assert_failure 2
}

@test "notify show keeps the app name a popup was sent with, for the bell's groups (ar-3668)" {
  printf '#!/usr/bin/env bash\necho 41\n' > "$SANDBOX/bin/notify-send"
  printf '#!/usr/bin/env bash\n[[ "$*" == *GetNameOwner* ]] && { echo "(\x27:1.7\x27,)"; exit; }\n' > "$SANDBOX/bin/gdbus"
  chmod +x "$SANDBOX/bin/notify-send" "$SANDBOX/bin/gdbus"
  export XDG_RUNTIME_DIR="$FX/run"
  run "$DESK" notify show a -u normal -a Agents title body
  assert_success
  run "$DESK" notify show n --app-name="Needs you" title
  assert_success
  run "$DESK" notify show h -aHealth title
  assert_success
  assert_equal "$(cat "$FX/run/desk/notify-a.id")" "41 (':1.7',) Agents"
  assert_equal "$(cat "$FX/run/desk/notify-n.id")" "41 (':1.7',) Needs you"
  assert_equal "$(cat "$FX/run/desk/notify-h.id")" "41 (':1.7',) Health"
  # A bus that does not answer leaves no owner, and then no app to misread as one.
  printf '#!/usr/bin/env bash\nexit 1\n' > "$SANDBOX/bin/gdbus"
  run "$DESK" notify show a -a Agents title
  assert_success
  assert_equal "$(cat "$FX/run/desk/notify-a.id")" "41 "
}

# bell_fixture COUNT: swaync's stream says COUNT wait; the kept pages are three Agents and two
# Health from notifier :1.7, one Health from an earlier notifier :1.3 and one with no app name.
bell_fixture() {
  printf '#!/usr/bin/env bash\necho "{\\"text\\": \\"%s\\", \\"alt\\": \\"notification\\", \\"tooltip\\": \\"%s Notifications\\", \\"class\\": \\"notification\\"}"\n' "$1" "$1" > "$SANDBOX/bin/swaync-client"
  printf '#!/usr/bin/env bash\n[[ "$*" == *GetNameOwner* ]] && { echo "(\x27:1.7\x27,)"; exit; }\n' > "$SANDBOX/bin/gdbus"
  chmod +x "$SANDBOX/bin/swaync-client" "$SANDBOX/bin/gdbus"
  export XDG_RUNTIME_DIR="$FX/run"
  mkdir -p "$FX/run/desk" "$(dirname "$STATE")" && echo "notify=swaync" > "$STATE"
  local k
  for k in "a1 11 :1.7 Agents" "a2 12 :1.7 Agents" "a3 13 :1.7 Agents" "h1 21 :1.7 Health" "h2 22 :1.7 Health" "old 31 :1.3 Health"; do
    set -- $k
    printf "%s ('%s',) %s\n" "$2" "$3" "$4" > "$FX/run/desk/notify-$1.id"
  done
  printf "41 (':1.7',)\n" > "$FX/run/desk/notify-plain.id"
}

@test "notify bell counts the waiting pages by group and forgets the one its notifier closed (ar-3668)" {
  bell_fixture 8
  # NotificationClosed as dbus-monitor prints it: id 12 from this notifier, id 21 from another.
  cat > "$SANDBOX/bin/dbus-monitor" <<'EOF'
#!/usr/bin/env bash
printf 'signal time=1.0 sender=:1.7 -> destination=(null destination) serial=9 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=NotificationClosed\n   uint32 12\n   uint32 2\n'
printf 'signal time=1.1 sender=:1.3 -> destination=(null destination) serial=4 path=/org/freedesktop/Notifications; interface=org.freedesktop.Notifications; member=NotificationClosed\n   uint32 21\n   uint32 2\n'
EOF
  chmod +x "$SANDBOX/bin/dbus-monitor"
  run "$DESK" notify bell
  assert_success
  # The two streams interleave in any order, and the last line is the state after both.
  last="$(tail -n 1 <<<"$output")"
  assert_equal "$(jq -r .text <<<"$last")" " 2 agents, 2 health"
  assert_equal "$(jq -r .tooltip <<<"$last")" $'8 Notifications\nAgents 2, Health 2'
  assert_equal "$(jq -r .alt <<<"$last")" notification
  [ ! -e "$FX/run/desk/notify-a2.id" ]
  [ -e "$FX/run/desk/notify-h1.id" ]
}

@test "notify bell names no group while swaync says nothing waits, forgets every kept id, and is swaync's only (ar-3668)" {
  bell_fixture 0
  printf '#!/usr/bin/env bash\n' > "$SANDBOX/bin/dbus-monitor"
  chmod +x "$SANDBOX/bin/dbus-monitor"
  run "$DESK" notify bell
  assert_success
  assert_equal "$(jq -r .text <<<"$output")" ""
  assert_equal "$(jq -r .tooltip <<<"$output")" "0 Notifications"
  run ls "$FX/run/desk"
  assert_output ""
  echo "notify=dunst" > "$STATE"
  run "$DESK" notify bell
  assert_failure 2
}

@test "notify bell ends with swaync's stream though dbus-monitor still runs, so the bar restarts it (ar-3668)" {
  bell_fixture 2
  # dbus-monitor that never prints and never exits: only the bell's kill ends it.
  printf '#!/usr/bin/env bash\nmkfifo "$FX/never" && read -r _ < "$FX/never"\n' > "$SANDBOX/bin/dbus-monitor"
  chmod +x "$SANDBOX/bin/dbus-monitor"
  run timeout 20 "$DESK" notify bell
  assert_success
  assert_equal "$(jq -r .text <<<"$output")" " 2 agents, 2 health"
}

@test "notify show passes on the clicked action of a --wait popup, and a / in a tag stays out of the path" {
  # notify-send -p --wait: the id, then the action once the popup closes.
  printf '#!/usr/bin/env bash\necho 88; echo default\n' > "$SANDBOX/bin/notify-send"
  printf '#!/usr/bin/env bash\n[[ "$*" == *GetNameOwner* ]] && { echo "(\x27:1.7\x27,)"; exit; }\necho "gdbus ${*: -1}" >> "$FX/calls.log"\n' > "$SANDBOX/bin/gdbus"
  chmod +x "$SANDBOX/bin/notify-send" "$SANDBOX/bin/gdbus"
  export XDG_RUNTIME_DIR="$FX/run"
  run "$DESK" notify show "page:ci/main" -A default=Open --wait title body
  assert_success
  assert_output default
  assert_equal "$(cat "$FX/run/desk/notify-page:ci%main.id")" "88 (':1.7',)"
  run "$DESK" notify drop "page:ci/main"
  assert_equal "$(cat "$FX/calls.log")" "gdbus 88"
}

@test "panel toggles a chip's dropdown or a Noctalia panel, and sends the letters to every chip" {
  printf '#!/usr/bin/env bash\necho "noctalia $*" >> "$FX/calls.log"\n' > "$SANDBOX/bin/noctalia" && chmod +x "$SANDBOX/bin/noctalia"
  mkdir -p "$(dirname "$STATE")" && echo "bar=noctalia" > "$STATE"
  "$DESK" panel custom/ci
  "$DESK" panel control-center audio
  "$DESK" panel letters 'custom/ci=c custom/fleet=f'
  "$DESK" panel letters off
  run cat "$FX/calls.log"
  assert_output "noctalia msg panel-toggle dotfiles/chips:detail custom/ci
noctalia msg panel-toggle control-center audio
noctalia msg plugin dotfiles/chips:chip all letters custom/ci=c custom/fleet=f
noctalia msg plugin dotfiles/chips:chip all letters off"
}

@test "panel under waybar exits 2 and names the bar, without calling noctalia" {
  on_waybar
  printf '#!/usr/bin/env bash\necho "noctalia $*" >> "$FX/calls.log"\n' > "$SANDBOX/bin/noctalia" && chmod +x "$SANDBOX/bin/noctalia"
  run "$DESK" panel custom/ci
  assert_failure 2
  assert_output --partial 'the bar is waybar-classic'
  [ ! -e "$FX/calls.log" ]
}

@test "every Super+A b key is used once, and its chips are exactly the noctalia chips with a dropdown" {
  load '../helpers/hypr'
  local leaves
  leaves="$(hypr_dump registry | jq -r '.[] | select(.submap == "pinbar-panels" and (.arg | test("desk panel")))
    | "\(.key) \(.arg | capture("desk panel (?<t>[^ ]+)").t)"')"
  [ "$(wc -l <<<"$leaves")" -gt 10 ]
  run bash -c 'cut -d" " -f1 | sort | uniq -d' <<<"$leaves"
  assert_output ''
  run python3 -c '
import sys, tomllib
w = tomllib.load(open(sys.argv[1], "rb"))["widget"]
chips = {v["module"] for v in w.values() if v.get("module") and v.get("dropdown", True)}
want = {l.split()[1] for l in sys.argv[2].splitlines() if l.split()[1].startswith("custom/")}
bad = ["no chip: " + m for m in sorted(want - chips)] + ["no key: " + m for m in sorted(chips - want)]
print(*bad, sep="\n")
sys.exit(1 if bad else 0)
' "$REPO_ROOT/.config/noctalia/config.toml" "$leaves"
  assert_success
}

@test "every chip divider is before or after" {
  run grep -E '^divider = ' "$REPO_ROOT/.config/noctalia/config.toml"
  assert_success
  run grep -vE '^divider = "(before|after)"$' <<<"$output"
  assert_failure
}
